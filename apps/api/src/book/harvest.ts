// Stage 1 — "Brand Scout" harvester.
//
// Fans out every retrievable data point for a domain across the platform's
// scrape verbs, VERIFIES each result, ESCALATES tools on resistance, and
// FAILS LOUD: every point lands in `provenance` with status ok|failed + the
// winning tool + attempts. A point that legitimately has no data (e.g. "no
// LinkedIn ads") is a recorded TRUE-NEGATIVE (status:"ok", empty data) — never
// retried, never a silent empty.
//
// Output is a section-keyed, provenance-stamped `BrandSubstrate`. Stage 2's
// editor (composeBookData) AUTHORS from this substrate without re-scraping.
//
// Deferred to a later pass (tracked as TODO, NOT built here — design doc P2
// #14): press/news, founders-people/leadership, on-site & off-site reviews,
// UGC/creator-mention aggregation, sentiment scoring, competitor
// auto-discovery, sitemap taxonomy.

import type { Bindings } from "../env.js";
import { harvestCatalog } from "../catalog/routes.js";
import { captureScreenshot } from "../agent/screenshot-fetch.js";
import { mirrorToR2 } from "../mirror/routes.js";
import {
  type ContextBrandResponse,
  getFonts,
  getStyleguide,
  retrieveBrand,
} from "../scrape/context.js";
import {
  type Company,
  backfillCompanyFirmographics,
  fetchCompany,
} from "../scrape/thecompanies.js";
import { fetchLogo } from "../agent/logo-fetch.js";
import { imagePart } from "../llm/image-input.js";
import { scrapeHomepageEvidence } from "../agent/homepage-scrape.js";
import { harvestMultiPage } from "../agent/multipage-text.js";
import {
  linkedinAdsSearch,
  metaAdLibrarySearch,
} from "../scrape/scrapecreators.js";
import { scrapeGoogleAds } from "../scrape/google_ads.js";
import {
  instagram,
  linkedin,
  tiktok,
  youtube,
} from "../scrape/social.js";

// ── Substrate types ──────────────────────────────────────────────────────────

/** One data point's provenance — the loud-failure / true-negative contract. */
export interface ProvenanceEntry {
  /** Dotted point id, e.g. "identity.palette" | "social.tiktok" | "ads.meta". */
  point: string;
  /** "ok" = we have a verified result OR a verified true-negative (empty data).
   *  "failed" = the escalation chain was exhausted without a usable result. */
  status: "ok" | "failed";
  /** The winning tool, or the last tool tried on failure. */
  tool: string;
  /** Every rung tried, in order (verify summaries + escalation reasons). */
  attempts: string[];
  /** Present iff status==="failed" — the last/aggregate error. */
  error?: string;
}

export interface IdentitySubstrate {
  logo: { url: string; source: string } | null;
  /** Always-unioned palette: context.dev + design.tokens + homepage
   *  theme-color/CSS-vars/dominant + (when thin) a vision pass. */
  palette: Array<{ hex: string; name: string; role?: string }>;
  fonts: Array<{ family: string; role?: string }>;
  styleguide: Record<string, unknown> | null;
  screenshot_r2: string | null;
  voice: string[];
  slogan: string | null;
}

export interface CompanySubstrate {
  name: string | null;
  description: string | null;
  tagline: string | null;
  industry: string | null;
  naics: string[];
  sic: string[];
  employeeRange: string | null;
  employeeCount: number | null;
  country: string | null;
  city: string | null;
  founded: number | null;
  revenue: string | null;
  socials: Record<string, string>;
  /** Which null firmographic fields Valyu backfilled. */
  backfilled: string[];
}

export interface CatalogSubstrate {
  products: Array<Record<string, unknown>>;
  productCount: number;
  strategy: string;
}

export interface SocialProfile {
  /** Normalised profile facts (followers, verified, bio, url) plus raw. */
  profile: Record<string, unknown> | null;
  topPosts: Array<Record<string, unknown>>;
}

export interface AdRecordSubstrate {
  external_id: string;
  body: string | null;
  cta: string | null;
  url: string | null;
  source: string;
  /** Mirrored creative image, if any. */
  creative_r2?: string;
}

export interface CreativeAnalysis {
  external_id: string;
  source: string;
  hook?: string;
  mood?: string;
  observed_colors?: string[];
  text_overlays?: string[];
  notes?: string;
}

export interface MediaAsset {
  kind: string;
  r2_url: string;
  source: string;
}

/** The full, section-keyed, provenance-stamped harvest substrate. */
export interface BrandSubstrate {
  domain: string;
  /** How the canonical domain was resolved (input | brand-fetch | as-given). */
  resolvedFrom: string;
  identity: IdentitySubstrate;
  company: CompanySubstrate;
  catalog: CatalogSubstrate;
  /** Keyed by platform ("instagram" | "tiktok" | "youtube" | "linkedin"). */
  social: Record<string, SocialProfile>;
  ads: {
    meta: AdRecordSubstrate[];
    google: AdRecordSubstrate[];
    linkedin: AdRecordSubstrate[];
    creativeAnalysis: CreativeAnalysis[];
  };
  media: MediaAsset[];
  provenance: ProvenanceEntry[];
}

export interface HarvestBrandArgs {
  domain: string;
  tenant: string;
  competitors?: string[];
  ctx?: ExecutionContext;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const VISION_MODEL = "minimax/minimax-m3";

function normHost(domain: string): string {
  return domain.replace(/^https?:\/\//i, "").replace(/\/+$/, "").toLowerCase();
}

function brandNameFromDomain(domain: string): string {
  const slug = normHost(domain).replace(/^www\./, "").split(".")[0] ?? domain;
  return slug.charAt(0).toUpperCase() + slug.slice(1);
}

function normalizeHex(raw: string): string | null {
  const v = raw.trim().toLowerCase();
  if (/^#[0-9a-f]{6}$/.test(v)) return v;
  if (/^#[0-9a-f]{3}$/.test(v)) return "#" + v.slice(1).split("").map((c) => c + c).join("");
  return null;
}

/** A provenance recorder that owns its attempt log per point. */
class Prov {
  private attempts: string[] = [];
  constructor(
    private readonly point: string,
    private readonly sink: ProvenanceEntry[],
  ) {}
  note(msg: string): void {
    this.attempts.push(msg);
  }
  ok(tool: string, summary?: string): void {
    if (summary) this.attempts.push(summary);
    this.sink.push({ point: this.point, status: "ok", tool, attempts: this.attempts });
  }
  fail(tool: string, error: string): void {
    this.attempts.push(error);
    this.sink.push({ point: this.point, status: "failed", tool, attempts: this.attempts, error });
  }
}

/** Vision pass over an image URL — derive extra palette swatches or analyse an
 *  ad creative. Returns null when OpenRouter is unconfigured / fails (callers
 *  treat null as "vision unavailable", not a hard error). */
async function visionJson<T>(
  apiKey: string | undefined,
  imageUrl: string,
  prompt: string,
): Promise<T | null> {
  if (!apiKey) return null;
  try {
    const r = await fetch(OPENROUTER_ENDPOINT, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
        "http-referer": "https://brandnana.net",
        "x-title": "brandnana",
      },
      body: JSON.stringify({
        model: VISION_MODEL,
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: prompt },
              await imagePart(imageUrl),
            ],
          },
        ],
        temperature: 0.2,
        max_tokens: 800,
        response_format: { type: "json_object" },
      }),
    });
    if (!r.ok) return null;
    const data = (await r.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const raw = data.choices?.[0]?.message?.content ?? "";
    const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
    return JSON.parse(cleaned) as T;
  } catch {
    return null;
  }
}

// ── Section harvesters ───────────────────────────────────────────────────────

async function harvestIdentity(
  env: Bindings,
  domain: string,
  brandName: string,
  brand: ContextBrandResponse | null,
  prov: ProvenanceEntry[],
  media: MediaAsset[],
  ctx?: ExecutionContext,
): Promise<IdentitySubstrate> {
  const id: IdentitySubstrate = {
    logo: null,
    palette: [],
    fonts: [],
    styleguide: null,
    screenshot_r2: null,
    voice: [],
    slogan: null,
  };

  // Run the independent identity legs in parallel.
  const [logoOutcome, fontsRes, styleguideRes, evidence, shot, multiPage] = await Promise.all([
    fetchLogo(domain, { logoDevToken: env.CONTEXT_DEV_API_KEY }).catch(() => null),
    getFonts(env, domain, brandName, ctx).catch((e) => ({ __err: (e as Error).message })),
    getStyleguide(env, domain, brandName, ctx).catch((e) => ({ __err: (e as Error).message })),
    scrapeHomepageEvidence(domain, { browser: env.BROWSER }).catch(() => null),
    captureScreenshot(env, { domain, kind: "viewport", tenant: brandName, ctx }),
    harvestMultiPage({ domain, browser: env.BROWSER }).catch(() => null),
  ]);

  // ── logo (cascade) + mirror ──────────────────────────────────────────────
  {
    const p = new Prov("identity.logo", prov);
    if (logoOutcome?.result) {
      const r2 = await mirrorToR2(env, logoOutcome.result.url, ctx);
      id.logo = { url: r2 ?? logoOutcome.result.url, source: logoOutcome.result.source };
      if (r2) media.push({ kind: "logo", r2_url: r2, source: logoOutcome.result.source });
      p.ok("logo-cascade", `${logoOutcome.result.source}${r2 ? " (mirrored)" : " (mirror-miss, hot-link)"}`);
    } else {
      const tried = logoOutcome?.attempts.map((a) => `${a.source}=${a.reason ?? "fail"}`).join(", ") ?? "no attempts";
      p.fail("logo-cascade", `all logo sources failed: ${tried}`);
    }
  }

  // ── palette: ALWAYS-UNION context.dev + design.tokens + homepage signals ──
  {
    const p = new Prov("identity.palette", prov);
    const palette: Array<{ hex: string; name: string; role?: string }> = [];
    const seen = new Set<string>();
    const add = (raw: string | undefined, name: string, role?: string): void => {
      if (!raw) return;
      const hex = normalizeHex(raw);
      if (hex && !seen.has(hex)) {
        seen.add(hex);
        palette.push({ hex, name: name || hex, role });
      }
    };
    // context.dev / design.tokens colors (the vendor palette).
    const vColors = brand?.brand?.colors ?? [];
    vColors.forEach((c, i) => add(c.hex, c.name ?? `brand ${i + 1}`, i === 0 ? "primary" : i === 1 ? "secondary" : undefined));
    p.note(`context.dev: ${vColors.length} colors`);
    // homepage theme-color (seed it — design doc P1 #6).
    if (evidence && !evidence.fetch_error) {
      add(evidence.meta.theme_color, "theme-color");
      for (const v of evidence.brand_css_vars) add(v.value, v.name.replace(/^--/, ""));
      for (const c of evidence.colors_ranked) add(c.hex, c.via[0] ?? "dominant");
      p.note(`homepage: theme=${evidence.meta.theme_color ?? "—"} vars=${evidence.brand_css_vars.length} ranked=${evidence.colors_ranked.length}`);
    } else if (evidence?.fetch_error) {
      p.note(`homepage scrape failed: ${evidence.fetch_error}`);
    }
    // Vision fallback if still thin (<6 swatches) and we have a screenshot.
    if (palette.length < 6 && shot.ok && shot.r2_url) {
      const v = await visionJson<{ colors?: string[] }>(
        env.OPENROUTER_API_KEY,
        shot.r2_url,
        `Look at this brand homepage screenshot for "${brandName}". Return JSON {"colors":["#hex", ...]} listing the 6-10 most prominent brand colors as hex.`,
      );
      let added = 0;
      for (const c of v?.colors ?? []) {
        const before = palette.length;
        add(c, "vision");
        if (palette.length > before) added++;
      }
      p.note(`vision pass: +${added} swatches`);
    }
    id.palette = palette;
    if (palette.length > 0) p.ok("union+vision", `${palette.length} swatches`);
    else p.fail("union+vision", "no palette recoverable from any source");
  }

  // ── fonts ─────────────────────────────────────────────────────────────────
  {
    const p = new Prov("identity.fonts", prov);
    if (fontsRes && !("__err" in fontsRes) && fontsRes.fonts?.length) {
      const sorted = [...fontsRes.fonts].sort((a, b) => (b.percent_words ?? 0) - (a.percent_words ?? 0));
      id.fonts = sorted.map((f, i) => ({ family: f.font, role: i === 0 ? "primary" : i === 1 ? "secondary" : "accent" }));
      p.ok("context.dev/fonts", `${id.fonts.length} fonts, primary=${id.fonts[0]?.family}`);
    } else if (evidence && !evidence.fetch_error && evidence.fonts.length) {
      id.fonts = evidence.fonts.map((f, i) => ({ family: f.family, role: i === 0 ? "primary" : "secondary" }));
      p.ok("homepage-css", `${id.fonts.length} fonts from CSS`);
    } else {
      const err = fontsRes && "__err" in fontsRes ? fontsRes.__err : "no fonts found";
      p.fail("context.dev/fonts", err);
    }
  }

  // ── styleguide ──────────────────────────────────────────────────────────────
  {
    const p = new Prov("identity.styleguide", prov);
    if (styleguideRes && !("__err" in styleguideRes) && styleguideRes.styleguide) {
      id.styleguide = styleguideRes.styleguide;
      p.ok("context.dev/styleguide", `mode=${styleguideRes.styleguide.mode ?? "—"}`);
    } else {
      const err = styleguideRes && "__err" in styleguideRes ? styleguideRes.__err : "no styleguide";
      p.fail("context.dev/styleguide", err);
    }
  }

  // ── screenshot → R2 ──────────────────────────────────────────────────────
  {
    const p = new Prov("identity.screenshot", prov);
    if (shot.ok && shot.r2_url) {
      id.screenshot_r2 = shot.r2_url;
      media.push({ kind: "screenshot", r2_url: shot.r2_url, source: shot.source });
      p.ok(shot.source, "screenshot captured + mirrored to R2");
    } else {
      p.fail(shot.source, shot.error ?? "screenshot capture failed across all rungs");
    }
  }

  // ── voice + slogan ──────────────────────────────────────────────────────
  {
    const p = new Prov("identity.voice", prov);
    id.slogan = brand?.brand?.slogan ?? null;
    const notes: string[] = [];
    if (brand?.brand?.description) notes.push(brand.brand.description);
    if (multiPage && multiPage.pages.length) {
      for (const pg of multiPage.pages.slice(0, 4)) {
        if (pg.text) notes.push(`[${pg.kind}] ${pg.text.slice(0, 280)}`);
      }
      p.note(`multipage: ${multiPage.pages.length} pages, ${multiPage.total_text_bytes}B`);
    }
    id.voice = notes;
    if (notes.length || id.slogan) p.ok("brand+multipage", `slogan=${id.slogan ?? "—"} · ${notes.length} voice notes`);
    else p.fail("brand+multipage", "no voice signal (no description, no page copy)");
  }

  return id;
}

async function harvestCompany(
  env: Bindings,
  domain: string,
  brandName: string,
  brand: ContextBrandResponse | null,
  prov: ProvenanceEntry[],
  ctx?: ExecutionContext,
): Promise<CompanySubstrate> {
  const p = new Prov("company", prov);
  let base: Company | null = null;
  try {
    base = await fetchCompany(env, { domain, tenant: brandName, ctx });
    p.note(base ? "thecompaniesapi: record found" : "thecompaniesapi: 404 (unknown domain) — true-negative");
  } catch (e) {
    p.note(`thecompaniesapi error: ${(e as Error).message}`);
  }

  // Valyu-backfill null firmographics (founded / HQ / employees / revenue).
  const back = await backfillCompanyFirmographics(env, { base, domain, brandName, tenant: brandName, ctx });
  for (const w of back.warnings) p.note(w);
  if (back.filled.length) p.note(`valyu backfilled: ${back.filled.join(", ")}`);
  if (back.unresolved.length) p.note(`valyu unresolved: ${back.unresolved.join(", ")}`);
  const c = back.company;

  // Merge brand-fetch socials so we have the widest set of handles to fan out.
  const socials: Record<string, string> = { ...c.socials };
  for (const [net, url] of Object.entries(brand?.brand?.socials ?? {})) {
    if (typeof url === "string" && url && !socials[net]) socials[net] = url;
  }

  const sub: CompanySubstrate = {
    name: c.name ?? brand?.brand?.title ?? brandName,
    description: c.description ?? brand?.brand?.description ?? null,
    tagline: c.tagline ?? brand?.brand?.slogan ?? null,
    industry: c.industry ?? brand?.brand?.industry?.name ?? null,
    naics: c.naics,
    sic: c.sic,
    employeeRange: c.employeeRange,
    employeeCount: c.employeeCount,
    country: c.country,
    city: c.city,
    founded: c.founded,
    revenue: c.revenue,
    socials,
    backfilled: back.filled.map(String),
  };

  // "ok" whenever we got ANY firmographic or social signal — including a clean
  // true-negative (provider 404 but Valyu/brand-fetch gave us socials/name).
  const hasSignal = sub.name || sub.industry || sub.founded != null || Object.keys(socials).length > 0;
  if (hasSignal) p.ok(back.filled.length ? "thecompaniesapi+valyu" : "thecompaniesapi", `firmographics${sub.backfilled.length ? ` (+${sub.backfilled.length} backfilled)` : ""} · ${Object.keys(socials).length} socials`);
  else p.fail("thecompaniesapi+valyu", "no company signal from any provider");

  return sub;
}

async function harvestCatalogSection(
  env: Bindings,
  domain: string,
  brandName: string,
  prov: ProvenanceEntry[],
  media: MediaAsset[],
  ctx?: ExecutionContext,
): Promise<CatalogSubstrate> {
  const p = new Prov("catalog", prov);
  try {
    const res = await harvestCatalog(env, { domain, tenant: brandName, ctx });
    for (const w of res.warnings) p.note(w);
    // harvestCatalog already mirrors product images to R2 + attaches them to
    // each product's images[]; surface them in the media library too.
    for (const prod of res.products) {
      const imgs = prod.images as unknown;
      if (Array.isArray(imgs)) {
        for (const u of imgs) {
          if (typeof u === "string" && u.includes("/assets/")) {
            media.push({ kind: "product", r2_url: u, source: res.strategy });
          }
        }
      }
    }
    if (res.productCount > 0) p.ok(res.strategy, `${res.productCount} products · ${res.mirrored} images mirrored`);
    // True-negative: a real crawl that found zero products is recorded as ok
    // ONLY if the cascade ran cleanly; if warnings flag an actual failure
    // (host unreachable etc.) we record loud-failed.
    else if (res.warnings.some((w) => /unavailable|threw|error|failed|timeout/i.test(w)))
      p.fail(res.strategy, `0 products; cascade hit errors: ${res.warnings.slice(-2).join(" · ") || "unknown"}`);
    else p.ok(res.strategy, "0 products — verified true-negative (cascade ran clean, no catalog present)");
    return { products: res.products, productCount: res.productCount, strategy: res.strategy };
  } catch (e) {
    p.fail("auto-cascade", `harvestCatalog threw: ${(e as Error).message}`);
    return { products: [], productCount: 0, strategy: "auto:error" };
  }
}

/** Pull profile + a few top posts for one platform handle. */
async function harvestSocialPlatform(
  env: Bindings,
  platform: "instagram" | "tiktok" | "youtube" | "linkedin",
  handle: string,
  brandName: string,
  prov: ProvenanceEntry[],
  ctx?: ExecutionContext,
): Promise<SocialProfile> {
  const p = new Prov(`social.${platform}`, prov);
  const opts = { tenant: brandName, ctx };
  const out: SocialProfile = { profile: null, topPosts: [] };
  if (!env.SCRAPECREATORS_API_KEY) {
    p.fail(`social/${platform}`, "SCRAPECREATORS_API_KEY not configured");
    return out;
  }
  try {
    let profile: Record<string, unknown> | null = null;
    let posts: Record<string, unknown>[] = [];
    if (platform === "instagram") {
      profile = await instagram.profile(env, handle, opts) as Record<string, unknown> | null;
      const r = await instagram.userPosts(env, handle, opts) as { data?: unknown } | null;
      posts = extractList(r);
    } else if (platform === "tiktok") {
      profile = await tiktok.profile(env, handle, opts) as Record<string, unknown> | null;
      const r = await tiktok.profileVideos(env, handle, opts) as { data?: unknown } | null;
      posts = extractList(r);
    } else if (platform === "youtube") {
      profile = await youtube.channel(env, handle, opts) as Record<string, unknown> | null;
      const r = await youtube.channelVideos(env, handle, opts) as { data?: unknown } | null;
      posts = extractList(r);
    } else {
      profile = await linkedin.company(env, handle, opts) as Record<string, unknown> | null;
      const r = await linkedin.companyPosts(env, handle, opts) as { data?: unknown } | null;
      posts = extractList(r);
    }
    out.profile = profile;
    out.topPosts = posts.slice(0, 12);
    if (profile) p.ok(`social/${platform}`, `profile + ${out.topPosts.length} posts`);
    // True-negative: handle resolved but the platform returned nothing — ok.
    else p.ok(`social/${platform}`, "no profile returned — true-negative (handle absent or private)");
  } catch (e) {
    p.fail(`social/${platform}`, `${(e as Error).message}`);
  }
  return out;
}

/** Coax a list of posts/videos out of the various ScrapeCreators shapes. */
function extractList(r: unknown): Record<string, unknown>[] {
  if (!r || typeof r !== "object") return [];
  const o = r as Record<string, unknown>;
  for (const key of ["data", "items", "videos", "posts", "results", "aweme_list"]) {
    const v = o[key];
    if (Array.isArray(v)) return v as Record<string, unknown>[];
    if (v && typeof v === "object") {
      for (const k2 of ["items", "videos", "posts", "list"]) {
        const inner = (v as Record<string, unknown>)[k2];
        if (Array.isArray(inner)) return inner as Record<string, unknown>[];
      }
    }
  }
  return [];
}

/** Derive a bare handle from a social profile URL. */
function handleFromUrl(url: string): string | null {
  try {
    const u = new URL(url.startsWith("http") ? url : `https://${url}`);
    const seg = u.pathname.split("/").filter(Boolean);
    const last = seg[seg.length - 1] ?? "";
    return last.replace(/^@/, "") || null;
  } catch {
    return null;
  }
}

async function harvestSocial(
  env: Bindings,
  socials: Record<string, string>,
  brandName: string,
  prov: ProvenanceEntry[],
  ctx?: ExecutionContext,
): Promise<Record<string, SocialProfile>> {
  const platforms: Array<["instagram" | "tiktok" | "youtube" | "linkedin", string[]]> = [
    ["instagram", ["instagram"]],
    ["tiktok", ["tiktok"]],
    ["youtube", ["youtube"]],
    ["linkedin", ["linkedin"]],
  ];
  const jobs: Array<Promise<[string, SocialProfile]>> = [];
  for (const [platform, keys] of platforms) {
    const url = keys.map((k) => socials[k]).find(Boolean);
    const handle = url ? handleFromUrl(url) : null;
    if (!handle) {
      // No discovered handle = true-negative for that platform; record + skip.
      new Prov(`social.${platform}`, prov).ok(`social/${platform}`, "no handle discovered — true-negative (platform not in brand socials)");
      continue;
    }
    jobs.push(
      harvestSocialPlatform(env, platform, handle, brandName, prov, ctx).then((sp) => [platform, sp] as [string, SocialProfile]),
    );
  }
  const results = await Promise.all(jobs);
  const out: Record<string, SocialProfile> = {};
  for (const [k, v] of results) out[k] = v;
  return out;
}

async function harvestAds(
  env: Bindings,
  domain: string,
  brandName: string,
  screenshotForFallback: string | null,
  prov: ProvenanceEntry[],
  media: MediaAsset[],
  ctx?: ExecutionContext,
): Promise<BrandSubstrate["ads"]> {
  const ads: BrandSubstrate["ads"] = { meta: [], google: [], linkedin: [], creativeAnalysis: [] };
  const tenant = brandName;

  // ── Meta ───────────────────────────────────────────────────────────────
  {
    const p = new Prov("ads.meta", prov);
    if (!env.SCRAPECREATORS_API_KEY) {
      p.fail("scrapecreators/meta", "SCRAPECREATORS_API_KEY not configured");
    } else {
      try {
        const { ads: rows } = await metaAdLibrarySearch(env, { query: brandName, country: "US", tenant, ctx });
        for (const ad of rows) {
          const rec: AdRecordSubstrate = {
            external_id: ad.ad_archive_id,
            body: ad.snapshot?.page_name ?? null,
            cta: null,
            url: ad.snapshot?.page_profile_uri ?? null,
            source: "meta",
          };
          const img = typeof ad.snapshot?.page_profile_picture_url === "string" ? ad.snapshot.page_profile_picture_url : undefined;
          if (img) {
            const r2 = await mirrorToR2(env, img, ctx);
            if (r2) {
              rec.creative_r2 = r2;
              media.push({ kind: "ad-creative", r2_url: r2, source: "meta" });
            }
          }
          ads.meta.push(rec);
        }
        if (rows.length) p.ok("scrapecreators/meta", `${rows.length} meta ads`);
        else p.ok("scrapecreators/meta", `no meta ad-library matches — true-negative`);
      } catch (e) {
        p.fail("scrapecreators/meta", (e as Error).message);
      }
    }
  }

  // ── Google ───────────────────────────────────────────────────────────────
  {
    const p = new Prov("ads.google", prov);
    try {
      const g = await scrapeGoogleAds(env, { brand: brandName, tenant, ctx });
      if (g.source === "no_match" || !g.advertiser_id) {
        p.ok("scrape/google", g.warning ?? "no advertiser match — true-negative");
      } else {
        for (const cid of g.creative_ids) {
          ads.google.push({ external_id: cid, body: g.brand, cta: null, url: g.advertiser_url, source: "google" });
        }
        if (g.creative_ids.length) p.ok("scrape/google", `${g.creative_ids.length} google creatives (advertiser ${g.advertiser_id})`);
        else p.ok("scrape/google", `advertiser ${g.advertiser_id} found, 0 creatives extracted — true-negative`);
      }
    } catch (e) {
      p.fail("scrape/google", (e as Error).message);
    }
  }

  // ── LinkedIn ───────────────────────────────────────────────────────────
  {
    const p = new Prov("ads.linkedin", prov);
    if (!env.SCRAPECREATORS_API_KEY) {
      p.fail("scrapecreators/linkedin", "SCRAPECREATORS_API_KEY not configured");
    } else {
      try {
        const { ads: rows } = await linkedinAdsSearch(env, { query: brandName, tenant, ctx });
        let i = 0;
        for (const ad of rows) {
          ads.linkedin.push({
            external_id: ad.id ?? ad.ad_id ?? ad.creative_id ?? `linkedin-${brandName}-${i++}`,
            body: ad.headline ?? ad.body ?? ad.text ?? null,
            cta: ad.cta ?? ad.call_to_action ?? null,
            url: ad.url ?? ad.ad_url ?? null,
            source: "linkedin",
          });
        }
        if (rows.length) p.ok("scrapecreators/linkedin", `${rows.length} linkedin ads`);
        else p.ok("scrapecreators/linkedin", "no linkedin ad-library matches — true-negative");
      } catch (e) {
        p.fail("scrapecreators/linkedin", (e as Error).message);
      }
    }
  }

  // ── creative.analyze over each creative that carries an image (P2 #11) ──
  {
    const p = new Prov("ads.creativeAnalysis", prov);
    const withImage = ads.meta.filter((a) => a.creative_r2);
    let analysed = 0;
    for (const ad of withImage.slice(0, 8)) {
      const v = await visionJson<{ hook?: string; mood?: string; observed_colors?: string[]; text_overlays?: string[] }>(
        env.OPENROUTER_API_KEY,
        ad.creative_r2!,
        `Analyse this ad creative for "${brandName}". Return JSON {"hook":"...","mood":"...","observed_colors":["#hex"],"text_overlays":["..."]}.`,
      );
      if (v) {
        ads.creativeAnalysis.push({ external_id: ad.external_id, source: ad.source, ...v });
        analysed++;
      }
    }
    if (!env.OPENROUTER_API_KEY) p.fail("openrouter/vision", "OPENROUTER_API_KEY not configured");
    else if (withImage.length === 0) p.ok("openrouter/vision", "no mirrored ad creatives to analyse — true-negative");
    else p.ok("openrouter/vision", `analysed ${analysed}/${withImage.length} creatives`);
  }

  return ads;
}

// ── Orchestrator ─────────────────────────────────────────────────────────────

/**
 * Brand Scout — fan out every data point for `domain`, verify + escalate each,
 * fail LOUD into provenance, and mirror every binary to R2. Resolves to a
 * section-keyed `BrandSubstrate` the editor authors from without re-scraping.
 */
export async function harvestBrand(
  env: Bindings,
  args: HarvestBrandArgs,
): Promise<BrandSubstrate> {
  const ctx = args.ctx;
  const domain = normHost(args.domain);
  const tenant = args.tenant;
  const provenance: ProvenanceEntry[] = [];
  const media: MediaAsset[] = [];

  // ── resolve: brand.fetch gives us the canonical name + the seed socials. ──
  let brand: ContextBrandResponse | null = null;
  let resolvedFrom = "as-given";
  {
    const p = new Prov("resolve", provenance);
    try {
      brand = await retrieveBrand(env, domain, tenant, ctx);
      if (brand?.brand?.title) {
        resolvedFrom = "brand-fetch";
        p.ok("context.dev/brand", `resolved "${brand.brand.title}"`);
      } else {
        p.ok("context.dev/brand", "brand-fetch returned no title — using domain-derived name");
      }
    } catch (e) {
      p.fail("context.dev/brand", (e as Error).message);
    }
  }
  const brandName = brand?.brand?.title ?? brandNameFromDomain(domain);

  // ── identity + company first (company gives us the social handle set). ──
  // Run identity and company in parallel; both only need `brand`.
  const [identity, company] = await Promise.all([
    harvestIdentity(env, domain, brandName, brand, provenance, media, ctx),
    harvestCompany(env, domain, brandName, brand, provenance, ctx),
  ]);

  // ── catalog, social, ads — fan out in parallel (independent). ──
  const [catalog, social, ads] = await Promise.all([
    harvestCatalogSection(env, domain, brandName, provenance, media, ctx),
    harvestSocial(env, company.socials, brandName, provenance, ctx),
    harvestAds(env, domain, brandName, identity.screenshot_r2, provenance, media, ctx),
  ]);

  return {
    domain,
    resolvedFrom,
    identity,
    company,
    catalog,
    social,
    ads,
    media,
    provenance,
  };
}
