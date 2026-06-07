// `brandnana logo <domain>` — return real brand-accurate logos from multiple sources.
//
// Sources probed in parallel (5s timeout each), RANKED BY ASSET QUALITY in the
// confidence score (SOURCE_TIER_PTS) — not by probe order:
//   homepage scrape — the brand's own shipped <img>/<link rel=icon svg>  [best]
//   logo.dev        — official domain logos (LOGO_DEV_TOKEN; raster)
//   Wikipedia Commons — community SVGs, variable accuracy/recency
//   simpleicons.org — generic monochrome icon                       [last resort]
// SVG is strongly preferred over raster. Set LOGO_DEV_TOKEN so the official
// logo.dev source is acquired; without it the resolver leans on Wikipedia +
// homepage. brandfetch is deliberately excluded (paid API / hotlink-gated free
// tier) — see the note above probeLogoDev.
//
// All candidates with aspect_ratio 0.85–1.18 sourced from a favicon-shaped
// URL are moved to rejected[]. Real wordmarks are typically 2.5:1 to 5:1.

import { VERBS } from "@brandnana/schema";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { type LogoTags, LOGO_USER_AGENT, deriveSvgTags, tagRasterWithGroqVision } from "./logo-tags.js";
import { emit, progress, runAction, warn } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

// ── Types ────────────────────────────────────────────────────────────────────

export interface LogoCandidate {
  url: string;
  source: string;
  format: "svg" | "png" | "jpg" | "unknown";
  width?: number;
  height?: number;
  aspect_ratio?: number;
  confidence: number;
  rationale: string;
  /** Usage attributes (transparent / wordmark / mono / …) — see logo-tags.ts. */
  tags?: LogoTags;
}

export interface RejectedCandidate {
  url: string;
  source: string;
  format: "svg" | "png" | "jpg" | "unknown";
  width?: number;
  height?: number;
  aspect_ratio?: number;
  rejection_reason: string;
}

export interface LogoResult {
  domain: string;
  candidates: LogoCandidate[];
  recommended: number;
  rejected: RejectedCandidate[];
}

// ── In-process fetch cache (keyed by URL) ────────────────────────────────────

const fetchCache = new Map<string, string | null>();

async function cachedFetch(
  url: string,
  opts?: RequestInit,
  timeoutMs = 5000,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...opts, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function cachedFetchText(url: string, timeoutMs = 5000): Promise<string | null> {
  if (fetchCache.has(url)) return fetchCache.get(url) ?? null;
  try {
    const res = await cachedFetch(url, { headers: { "User-Agent": LOGO_USER_AGENT } }, timeoutMs);
    if (!res.ok) {
      fetchCache.set(url, null);
      return null;
    }
    const text = await res.text();
    fetchCache.set(url, text);
    return text;
  } catch {
    fetchCache.set(url, null);
    return null;
  }
}

// ── Format detection ─────────────────────────────────────────────────────────

function detectFormat(url: string, contentType?: string | null): "svg" | "png" | "jpg" | "unknown" {
  const lower = url.toLowerCase();
  if (lower.includes(".svg") || contentType?.includes("svg")) return "svg";
  if (lower.includes(".png") || contentType?.includes("png")) return "png";
  if (lower.includes(".jpg") || lower.includes(".jpeg") || contentType?.includes("jpeg")) return "jpg";
  return "unknown";
}

// ── Favicon-path detection ───────────────────────────────────────────────────

const FAVICON_RE = /favicon|apple-touch|icon-\d/i;

function isFaviconUrl(url: string): boolean {
  return FAVICON_RE.test(url);
}

// ── Aspect ratio validation ──────────────────────────────────────────────────

/**
 * Returns true when the candidate looks like an app icon (square/near-square)
 * AND its URL matches favicon patterns. Both signals required to avoid
 * rejecting legitimate square logomarks.
 */
export function isAppIconCandidate(
  url: string,
  aspectRatio: number | undefined,
): boolean {
  if (aspectRatio == null) return false;
  return isFaviconUrl(url) && aspectRatio >= 0.85 && aspectRatio <= 1.18;
}

/**
 * Reject a favicon-named asset that is NOT a confirmed wide wordmark — even when
 * its aspect ratio is unknown. tecovas.com shipped `favicon.svg` as a
 * dimensionless `<link rel=icon type=svg>`: with no width/height the aspect-ratio
 * guard `isAppIconCandidate` short-circuits to false and the favicon was
 * (wrongly) recommended as the brand logo. A favicon-pattern URL is a favicon by
 * default; it only survives if it has a CONFIRMED wide aspect (>= 2.5, the
 * wordmark band). A square (0.85–1.18) or dimensionless favicon is rejected.
 */
export function isFaviconReject(
  url: string,
  aspectRatio: number | undefined,
): boolean {
  if (!isFaviconUrl(url)) return false;
  // Confirmed wide wordmark → keep (a favicon-named file can occasionally be a
  // real lockup). Everything else favicon-named is rejected.
  if (aspectRatio != null && aspectRatio >= 2.5) return false;
  return true;
}

// ── Confidence scoring ───────────────────────────────────────────────────────

// Source weight is keyed by QUALITY of the asset that source yields, NOT probe
// order. The brand's own homepage and the official logo.dev provider outrank
// community-uploaded Wikipedia Commons and the generic simpleicons fallback.
// Tier numbers identify the source (see gatherCandidates); the value is its
// quality weight. 3 (brandfetch) is intentionally unused — see probeLogoDev.
const SOURCE_TIER_PTS: Record<number, number> = {
  1: 0.48, // homepage — the brand's own shipped asset
  4: 0.42, // logo.dev — official domain logos
  2: 0.20, // wikipedia commons — community SVGs, variable accuracy/recency
  5: 0.05, // simpleicons — generic monochrome icon, last resort
};

export function computeConfidence(opts: {
  sourceTier: 1 | 2 | 3 | 4 | 5;
  format: "svg" | "png" | "jpg" | "unknown";
  aspectRatio?: number;
  width?: number;
  svgConfirmed?: boolean;
}): number {
  const sourcePts = SOURCE_TIER_PTS[opts.sourceTier] ?? 0;
  // SVG is strongly preferred — scalable, brand-accurate, the deliverable format.
  const formatPts =
    opts.format === "svg" ? 0.30 :
    opts.format === "png" ? 0.15 :
    opts.format === "jpg" ? 0.05 : 0.0;
  // Wide aspect hints "wordmark", but it's only a heuristic — keep it small so
  // it can't let a community SVG leapfrog an official-source logo.
  const aspectPts =
    opts.aspectRatio != null && opts.aspectRatio >= 2.5 && opts.aspectRatio <= 5.0 ? 0.05 : 0.0;
  const sizePts = opts.width != null && opts.width >= 200 ? 0.05 : 0.0;
  // A byte-confirmed <svg> (not just a content-type guess) is the real thing.
  const svgConfirmedPts = opts.svgConfirmed ? 0.05 : 0.0;

  return Math.min(1.0, sourcePts + formatPts + aspectPts + sizePts + svgConfirmedPts);
}

// ── SVG dimension extraction ─────────────────────────────────────────────────

function parseSvgDimensions(svgText: string): { width?: number; height?: number } {
  const viewBoxMatch = svgText.match(/viewBox=["']([^"']+)["']/i);
  if (viewBoxMatch?.[1]) {
    const parts = viewBoxMatch[1].trim().split(/[\s,]+/);
    if (parts.length === 4) {
      const w = Number.parseFloat(parts[2] ?? "0");
      const h = Number.parseFloat(parts[3] ?? "0");
      if (w > 0 && h > 0) return { width: w, height: h };
    }
  }
  const wMatch = svgText.match(/\bwidth=["']([0-9.]+)/i);
  const hMatch = svgText.match(/\bheight=["']([0-9.]+)/i);
  const w = wMatch?.[1] ? Number.parseFloat(wMatch[1]) : undefined;
  const h = hMatch?.[1] ? Number.parseFloat(hMatch[1]) : undefined;
  if (w && h) return { width: w, height: h };
  return {};
}

// ── HTML parsing helpers ─────────────────────────────────────────────────────

// A probe hit, fully described by the source that produced it. Each provider
// knows its own contract (Wikipedia/simpleicons are always SVG, logo.dev is
// GET-only raster read from content-type), so it sets `format`
// deterministically. `format: "unknown"` is the ONLY case assembly
// content-probes — a homepage <img> whose URL carries no usable extension.
interface ProbeHit {
  url: string;
  note: string;
  format: "svg" | "png" | "jpg" | "unknown";
  width?: number;
  height?: number;
  svgConfirmed?: boolean;
}

const LOGO_SRC_RE = /logo|brand|wordmark/i;
const LOGO_ALT_RE = /logo|wordmark/i;

function resolveUrl(origin: string, src: string): string | null {
  try {
    return new URL(src, origin).toString();
  } catch {
    return null;
  }
}

/**
 * Parse logo candidates from raw HTML — exported for unit testing without
 * network calls.
 */
export function probeHomepageFromHtml(origin: string, html: string): ProbeHit[] {
  const results: ProbeHit[] = [];

  // <img src=...logo...> or alt contains logo/wordmark. Format comes from the
  // URL extension; an extensionless CDN URL stays "unknown" → content-probed.
  const imgTagRe = /<img[^>]+>/gi;
  let match: RegExpExecArray | null;
  while ((match = imgTagRe.exec(html)) !== null) {
    const tag = match[0];
    const srcMatch = tag.match(/src=["']([^"']+)["']/i);
    const altMatch = tag.match(/alt=["']([^"']*?)["']/i);
    if (!srcMatch?.[1]) continue;
    const src = srcMatch[1];
    const alt = altMatch?.[1] ?? "";
    if (LOGO_SRC_RE.test(src) || LOGO_ALT_RE.test(alt)) {
      const resolved = resolveUrl(origin, src);
      if (resolved) {
        results.push({ url: resolved, note: `homepage <img> (alt="${alt}")`, format: detectFormat(resolved) });
      }
    }
  }

  // <link rel="icon" type="image/svg+xml"> — the type attribute declares SVG.
  const linkRe = /<link[^>]+>/gi;
  while ((match = linkRe.exec(html)) !== null) {
    const tag = match[0];
    if (/rel=["'][^"']*icon[^"']*["']/i.test(tag) && /type=["'][^"']*svg[^"']*["']/i.test(tag)) {
      const hrefMatch = tag.match(/href=["']([^"']+)["']/i);
      if (hrefMatch?.[1]) {
        const resolved = resolveUrl(origin, hrefMatch[1]);
        if (resolved) results.push({ url: resolved, note: "homepage <link rel=icon type=svg>", format: "svg", svgConfirmed: true });
      }
    }
  }

  return results;
}

// ── Source 1: Homepage scrape ────────────────────────────────────────────────

async function probeHomepage(domain: string): Promise<ProbeHit[]> {
  const origin = `https://${domain}`;
  const html = await cachedFetchText(origin);
  if (!html) return [];

  const results = probeHomepageFromHtml(origin, html);

  // manifest.json — look for wide-aspect icons (likely wordmarks)
  const manifestLinkRe = /<link[^>]+rel=["'][^"']*manifest[^"']*["'][^>]*>/i;
  const manifestMatch = html.match(manifestLinkRe);
  if (manifestMatch) {
    const hrefMatch = manifestMatch[0].match(/href=["']([^"']+)["']/i);
    if (hrefMatch?.[1]) {
      const manifestUrl = resolveUrl(origin, hrefMatch[1]);
      if (manifestUrl) {
        const manifestText = await cachedFetchText(manifestUrl);
        if (manifestText) {
          try {
            const manifest = JSON.parse(manifestText) as {
              icons?: Array<{ src: string; sizes?: string; type?: string }>;
            };
            for (const icon of manifest.icons ?? []) {
              if (!icon.src) continue;
              const sizes = icon.sizes ?? "";
              const [wStr, hStr] = sizes.split("x");
              const w = Number.parseInt(wStr ?? "0", 10);
              const h = Number.parseInt(hStr ?? "0", 10);
              if (w > 0 && h > 0 && w / h >= 2.5) {
                const resolved = resolveUrl(origin, icon.src);
                if (resolved) {
                  const fmt = icon.type?.includes("svg") ? "svg" : detectFormat(resolved, icon.type);
                  results.push({ url: resolved, note: "manifest.json wide icon", format: fmt, width: w, height: h });
                }
              }
            }
          } catch {
            // malformed manifest — skip
          }
        }
      }
    }
  }

  return results;
}

// ── Source 2: Wikipedia Commons ──────────────────────────────────────────────

interface WikiSearchResult {
  title: string;
  // biome-ignore lint/suspicious/noExplicitAny: API response
  [k: string]: any;
}

async function probeWikipediaCommons(brandName: string): Promise<ProbeHit[]> {
  const results: ProbeHit[] = [];
  const query = encodeURIComponent(`${brandName} logo`);
  const apiUrl =
    `https://commons.wikimedia.org/w/api.php?action=query&list=search` +
    `&srsearch=${query}+filetype:svg&srnamespace=6&srlimit=5&format=json&origin=*`;

  try {
    const res = await cachedFetch(apiUrl, { headers: { "User-Agent": LOGO_USER_AGENT } }, 5000);
    if (!res.ok) return results;
    const data = await res.json() as {
      query?: { search?: WikiSearchResult[] };
    };
    const hits = data.query?.search ?? [];
    for (const hit of hits.slice(0, 3)) {
      const title = hit.title as string;
      if (!title.toLowerCase().includes(".svg")) continue;
      const infoUrl =
        `https://commons.wikimedia.org/w/api.php?action=query&titles=${encodeURIComponent(title)}` +
        `&prop=imageinfo&iiprop=url&format=json&origin=*`;
      try {
        const infoRes = await cachedFetch(infoUrl, { headers: { "User-Agent": LOGO_USER_AGENT } }, 5000);
        if (!infoRes.ok) continue;
        const infoData = await infoRes.json() as {
          query?: { pages?: Record<string, { imageinfo?: Array<{ url: string }> }> };
        };
        const pages = infoData.query?.pages ?? {};
        for (const page of Object.values(pages)) {
          const imageUrl = page.imageinfo?.[0]?.url;
          if (imageUrl) {
            // The search is scoped to filetype:svg and titles are .svg-filtered,
            // so these are genuine Wikimedia SVGs — no content check needed.
            results.push({ url: imageUrl, note: `Wikipedia Commons (${title})`, format: "svg", svgConfirmed: true });
          }
        }
      } catch {
        // skip this hit
      }
    }
  } catch {
    // network error — skip
  }

  return results;
}

// brandfetch is intentionally NOT a source. Its Brand API (the only endpoint
// that returns validated official SVG logos server-side) is paid; the free Logo
// Link is browser-embed-only and gated by a per-domain referer allowlist, so it
// can't be validated server-side or guaranteed in a portable workbook. We rely
// on the free, server-side-validatable, embed-anywhere sources below instead.

// ── Source 4: logo.dev API ───────────────────────────────────────────────────

async function probeLogoDev(domain: string): Promise<ProbeHit[]> {
  // No silent dead-token fallback: the old hardcoded public pk is invalid
  // (404 "invalid api token"), which made logo.dev appear configured while
  // returning nothing. Require a real LOGO_DEV_TOKEN; skip cleanly without one.
  const token = process.env["LOGO_DEV_TOKEN"];
  if (!token) return [];
  // logo.dev's img endpoint is raster-only (`format=svg` is rejected) and 404s
  // on HEAD while serving the image on GET — so we GET, and read the real format
  // off the content-type. This is the provider's actual contract, not a guess.
  const url = `https://img.logo.dev/${domain}?token=${token}`;
  const results: ProbeHit[] = [];

  try {
    const res = await cachedFetch(
      url,
      { headers: { "User-Agent": LOGO_USER_AGENT, "Range": "bytes=0-2047" } },
      5000,
    );
    if (res.ok) {
      const ct = res.headers.get("content-type") ?? "";
      if (ct.includes("image")) {
        const fmt = detectFormat(url, ct);
        results.push({ url, note: "logo.dev API (official)", format: fmt === "unknown" ? "png" : fmt });
      }
    }
  } catch {
    // skip
  }

  return results;
}

// ── Source 5: simpleicons.org ────────────────────────────────────────────────

async function probeSimpleIcons(brandName: string): Promise<ProbeHit[]> {
  const slug = brandName.toLowerCase().replace(/[^a-z0-9]/g, "");
  const url = `https://simpleicons.org/icons/${slug}.svg`;
  const results: ProbeHit[] = [];

  try {
    const res = await cachedFetch(url, { method: "HEAD", headers: { "User-Agent": LOGO_USER_AGENT } }, 5000);
    if (res.ok) {
      // simpleicons serves only SVG, by path — known format, no content check.
      results.push({ url, note: "simpleicons.org (generic icon — last resort)", format: "svg", svgConfirmed: true });
    }
  } catch {
    // skip
  }

  return results;
}

// ── Brand name extraction from domain ───────────────────────────────────────

function brandNameFromDomain(domain: string): string {
  const sld = domain.replace(/^www\./, "").split(".")[0] ?? domain;
  return sld.charAt(0).toUpperCase() + sld.slice(1);
}

// ── Content probe (ONLY for unknown-format hits) ─────────────────────────────

interface Resolved {
  format: "svg" | "png" | "jpg" | "unknown";
  svgConfirmed: boolean;
  contentLength: number | null;
}

// Used solely to resolve a homepage <img> whose URL gave no extension. Every
// other source already states its format (see ProbeHit), so this never runs for
// them. One ranged GET — no HEAD, no provider guessing.
async function contentProbe(url: string): Promise<Resolved | null> {
  try {
    const res = await cachedFetch(
      url,
      { headers: { "User-Agent": LOGO_USER_AGENT, "Range": "bytes=0-2047" } },
      5000,
    );
    if (!res.ok) return null;
    const contentType = res.headers.get("content-type");
    const lenStr = res.headers.get("content-length");
    const contentLength = lenStr ? Number.parseInt(lenStr, 10) : null;
    const format = detectFormat(url, contentType);
    if (format === "unknown" && !contentType?.includes("image")) return null;
    let svgConfirmed = false;
    if (format === "svg") {
      const snippet = await res.text();
      svgConfirmed = /<svg/i.test(snippet);
    }
    return { format, svgConfirmed, contentLength };
  } catch {
    return null;
  }
}

// ── Main probe orchestration ─────────────────────────────────────────────────

type RawHit = ProbeHit & { source: string; tier: 1 | 2 | 3 | 4 | 5 };

async function gatherCandidates(domain: string): Promise<{ raw: RawHit[] }> {
  const brandName = brandNameFromDomain(domain);

  const settled = await Promise.allSettled([
    probeHomepage(domain),
    probeWikipediaCommons(brandName),
    probeLogoDev(domain),
    probeSimpleIcons(brandName),
  ]);

  // Tier IDs are stable (they key SOURCE_TIER_PTS): 1=homepage 2=wikipedia
  // 4=logo.dev 5=simpleicons. 3 (brandfetch) is intentionally absent.
  const tiers: Array<1 | 2 | 3 | 4 | 5> = [1, 2, 4, 5];
  const raw: RawHit[] = [];
  settled.forEach((res, i) => {
    if (res.status !== "fulfilled") return;
    for (const h of res.value) {
      raw.push({ ...h, source: h.note, tier: tiers[i] as 1 | 2 | 3 | 4 | 5 });
    }
  });

  return { raw };
}

// ── Build LogoResult ─────────────────────────────────────────────────────────

function buildRationale(
  source: string,
  format: "svg" | "png" | "jpg" | "unknown",
  aspectRatio: number | undefined,
  width: number | undefined,
  svgConfirmed: boolean,
): string {
  const parts: string[] = [];
  parts.push(`source: ${source}`);
  if (format === "svg") {
    parts.push(svgConfirmed ? "confirmed SVG" : "SVG format");
  } else if (format === "png") {
    parts.push("PNG format");
  }
  if (aspectRatio != null) {
    if (aspectRatio >= 2.5 && aspectRatio <= 5.0) {
      parts.push(`wide aspect ratio ${aspectRatio.toFixed(1)} (likely wordmark)`);
    } else {
      parts.push(`aspect ratio ${aspectRatio.toFixed(1)}`);
    }
  }
  if (width != null && width >= 200) {
    parts.push(`width ${width}px`);
  }
  return parts.join("; ");
}

// Enrich each candidate with usage tags. SVG → structural (exact, free);
// raster → Groq vision when GROQ_API_KEY is present. Best-effort: a failure
// leaves a candidate untagged, never drops it.
// Fetch SVG source for tagging. Bypasses cachedFetchText's null-caching (which
// would pin a transient failure) and retries once — a burst of parallel
// Wikimedia fetches otherwise 429s a couple of candidates into staying untagged.
async function fetchSvgForTag(url: string): Promise<string | null> {
  const cached = fetchCache.get(url);
  if (cached) return cached;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await cachedFetch(url, { headers: { "User-Agent": LOGO_USER_AGENT } }, 5000);
      if (res.ok) {
        const text = await res.text();
        fetchCache.set(url, text);
        return text;
      }
    } catch {
      // retry
    }
    await new Promise((r) => setTimeout(r, 250 * (attempt + 1)));
  }
  return null;
}

async function tagCandidates(candidates: LogoCandidate[]): Promise<void> {
  const groqKey = process.env["GROQ_API_KEY"];

  // Raster → Groq vision, in parallel (independent hosts).
  const raster = groqKey
    ? Promise.allSettled(
        candidates
          .filter((c) => c.format !== "svg")
          .map(async (c) => {
            const tags = await tagRasterWithGroqVision(c.url, groqKey);
            if (tags) c.tags = tags;
          }),
      )
    : Promise.resolve();

  // SVG → structural, SEQUENTIALLY: these mostly hit one host (Wikimedia), and
  // a parallel burst alongside the gather-phase API calls trips its rate limit.
  const svgWork = (async () => {
    for (const c of candidates.filter((c) => c.format === "svg")) {
      try {
        const svg = await fetchSvgForTag(c.url);
        if (svg) c.tags = deriveSvgTags(svg);
      } catch {
        // best-effort: leave untagged
      }
    }
  })();

  await Promise.allSettled([raster, svgWork]);
}

async function buildLogoResult(domain: string, skipSimpleIcons: boolean, tag = true): Promise<LogoResult> {
  const { raw } = await gatherCandidates(domain);

  // Deduplicate by URL
  const seen = new Set<string>();
  const deduped = raw.filter((r) => {
    if (seen.has(r.url)) return false;
    seen.add(r.url);
    return true;
  });

  const candidates: LogoCandidate[] = [];
  const rejected: RejectedCandidate[] = [];

  // Each hit already carries its provider-known format; the ONLY work left is to
  // resolve homepage <img>s whose URL gave no extension (format "unknown").
  const resolved = await Promise.allSettled(
    deduped.map(async (r) => {
      if (r.format !== "unknown") return r;
      const probed = await contentProbe(r.url);
      if (!probed) return null;
      // PNG too small = likely a tracker pixel, not a logo.
      if (probed.format === "png" && probed.contentLength != null && probed.contentLength < 4000) return null;
      return { ...r, format: probed.format, svgConfirmed: probed.svgConfirmed };
    }),
  );

  for (const v of resolved) {
    if (v.status !== "fulfilled" || v.value == null) continue;
    const r = v.value;
    const format = r.format;
    const svgConfirmed = r.svgConfirmed ?? false;

    if (skipSimpleIcons && r.tier === 5) continue;

    let width = r.width;
    let height = r.height;

    if (format === "svg" && (!width || !height)) {
      const svgText = fetchCache.get(r.url);
      if (svgText) {
        const dims = parseSvgDimensions(svgText);
        width = dims.width ?? width;
        height = dims.height ?? height;
      }
    }

    const aspectRatio = width && height ? width / height : undefined;

    // Favicon-named asset with no confirmed wide-wordmark aspect → reject,
    // regardless of whether we could measure its dimensions. This catches the
    // dimensionless `favicon.svg` <link rel=icon> case that the aspect-ratio-only
    // guard (isAppIconCandidate) silently let through.
    if (isFaviconReject(r.url, aspectRatio)) {
      rejected.push({
        url: r.url,
        source: r.source,
        format,
        width,
        height,
        aspect_ratio: aspectRatio,
        rejection_reason: "favicon_or_app_icon — favicon-named asset, not a wordmark",
      });
      continue;
    }

    if (isAppIconCandidate(r.url, aspectRatio)) {
      rejected.push({
        url: r.url,
        source: r.source,
        format,
        width,
        height,
        aspect_ratio: aspectRatio,
        rejection_reason: "aspect_ratio_app_icon — square graphic, not a wordmark",
      });
      continue;
    }

    const confidence = computeConfidence({
      sourceTier: r.tier,
      format,
      aspectRatio,
      width,
      svgConfirmed,
    });

    const rationale = buildRationale(r.source, format, aspectRatio, width, svgConfirmed);

    candidates.push({
      url: r.url,
      source: r.source,
      format,
      ...(width != null ? { width } : {}),
      ...(height != null ? { height } : {}),
      ...(aspectRatio != null ? { aspect_ratio: Math.round(aspectRatio * 100) / 100 } : {}),
      confidence: Math.round(confidence * 100) / 100,
      rationale,
    });
  }

  candidates.sort((a, b) => b.confidence - a.confidence);

  if (tag) await tagCandidates(candidates);

  return {
    domain,
    candidates,
    recommended: candidates.length > 0 ? 0 : -1,
    rejected,
  };
}

// ── Human format ─────────────────────────────────────────────────────────────

function formatHuman(result: LogoResult): string {
  const lines: string[] = [`logo candidates for ${result.domain}`];
  if (result.candidates.length === 0) {
    lines.push("  no candidates found");
  } else {
    for (let i = 0; i < result.candidates.length; i++) {
      const c = result.candidates[i]!;
      const tag = i === result.recommended ? " [recommended]" : "";
      lines.push(`  ${i + 1}. [${c.confidence.toFixed(2)}] ${c.url}${tag}`);
      lines.push(`       source: ${c.source}, format: ${c.format}`);
      if (c.aspect_ratio != null) lines.push(`       aspect: ${c.aspect_ratio}`);
    }
  }
  if (result.rejected.length > 0) {
    lines.push(`  rejected (${result.rejected.length}):`);
    for (const r of result.rejected) {
      lines.push(`    - ${r.url}: ${r.rejection_reason}`);
    }
  }
  return lines.join("\n");
}

// ── API-assisted homepage fetch ───────────────────────────────────────────────
//
// When the direct homepage scrape yields no candidates (WAF block), we fall
// back to calling POST /scrape on the managed API.  The API routes through
// cf-browser → context-dev → firecrawl and returns rendered HTML.  We then
// run the same probeHomepageFromHtml logic against that HTML.

async function fetchHomepageViaApi(
  domain: string,
  baseUrl?: string,
): Promise<string | null> {
  try {
    const client = await clientFromEnv(baseUrl);
    const scrapeResult = await client.scrape.fetch(`https://${domain}`, { expect: "html" });
    if (scrapeResult.ok && scrapeResult.body) {
      return scrapeResult.body;
    }
  } catch {
    // API fallback failed — caller will handle empty result
  }
  return null;
}

// ── Command registration ─────────────────────────────────────────────────────

interface LogoOptions {
  skipSimpleIcons: boolean;
  tag: boolean;
  mirror?: boolean;
  baseUrl?: string;
}

// ── R2 mirroring (--mirror) ───────────────────────────────────────────────────
//
// The standalone `logo` verb returns raw vendor URLs (homepage / wikipedia /
// logo.dev / simpleicons). The deterministic substrate builder marks a logo
// STATUS=ok ONLY when its URL is a canonical R2 asset
// (https://api.brandnana.net/assets/<sha>). With --mirror set we POST every
// candidate's bytes to /mirror/images and rewrite each candidate.url to the
// returned R2 URL in place, so the gathered raw/logo.json carries R2 URLs and
// the builder renders PRIMARY_URL=R2, STATUS=ok. Mirrors the catalog --mirror
// SDK pattern (catalog.ts mirrorImageUrls). Best-effort per URL: a URL that
// fails to mirror keeps its raw value (and the builder then renders it
// needs_mirror, never as a green hotlink).

async function mirrorLogoCandidates(
  result: LogoResult,
  baseUrl?: string,
): Promise<{ replaced: number; skipped: number }> {
  const urls = result.candidates.map((c) => c.url);
  if (urls.length === 0) return { replaced: 0, skipped: 0 };
  const client = await clientFromEnv(baseUrl);
  const mirror = (await client.mirror.images(urls)) as {
    mapping: Record<string, string>;
    skipped: string[];
  };
  let replaced = 0;
  let skipped = 0;
  for (const c of result.candidates) {
    const r2 = mirror.mapping[c.url];
    if (r2) {
      c.url = r2;
      replaced++;
    } else {
      skipped++;
    }
  }
  return { replaced, skipped };
}

export function registerLogo(program: Command): void {
  program
    .command("logo <domain>")
    .description(verbSummary("logo.find"))
    .option("--skip-simple-icons", "Skip simpleicons.org even if no other SVG was found", false)
    .option("--no-tag", "Skip usage tagging (SVG-structural + Groq vision on raster)")
    .option("--mirror", "Mirror each candidate to R2 and rewrite URLs to the canonical api.brandnana.net asset")
    .option("--base-url <url>", "Override API base URL (used for WAF-bypass fallback + mirroring)")
    .action((domain: string, opts: LogoOptions) =>
      runAction(async () => {
        progress(`probing logo sources for ${domain}…`);

        const hasBetterSources = !!process.env["LOGO_DEV_TOKEN"];
        const skipSimpleIcons = opts.skipSimpleIcons || hasBetterSources;

        let result = await buildLogoResult(domain, skipSimpleIcons, opts.tag);

        // If no candidates and homepage fetch likely WAF-blocked, try the managed
        // API which routes through cf-browser / context-dev / firecrawl.
        if (result.candidates.length === 0 && !fetchCache.get(`https://${domain}`)) {
          progress(`direct fetch blocked — retrying via managed API…`);
          const html = await fetchHomepageViaApi(domain, opts.baseUrl);
          if (html) {
            fetchCache.set(`https://${domain}`, html);
            // Re-run the full logo extraction now that we have the HTML.
            result = await buildLogoResult(domain, skipSimpleIcons, opts.tag);
          }
        }

        if (result.candidates.length === 0 && result.rejected.length > 0) {
          warn(`all ${result.rejected.length} candidate(s) rejected — try with a broader search`);
        }

        // Mirror to R2 so the gathered logo.json carries canonical asset URLs.
        if (opts.mirror && result.candidates.length > 0) {
          progress(`mirroring ${result.candidates.length} logo candidate(s) to R2…`);
          const { replaced, skipped } = await mirrorLogoCandidates(result, opts.baseUrl);
          progress(`mirrored: ${replaced} replaced, ${skipped} skipped`);
        }

        emit(result, formatHuman(result));
      }),
    );
}
