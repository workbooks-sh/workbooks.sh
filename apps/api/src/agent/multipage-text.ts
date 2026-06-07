// Multi-page text harvester — beyond the homepage. Pulls visible body text
// from About / Press / a sample PDP so Cerebras has real voice signal from
// across the site, not just hero headlines.
//
// Strategy:
//   1. Fetch homepage; from the same HTML extract candidate links to /about,
//      /press, /products, /shop, /journal, etc.
//   2. Fetch up to 5 of those pages in parallel (8s timeout each, 200KB cap).
//   3. Strip HTML tags + boilerplate (nav, footer, scripts, styles).
//   4. Return concatenated text + per-page summaries.

import type { Bindings } from "../env.js";
import { browserHeaders } from "../scrape/headers.js";
import { renderPage } from "../scrape/browser.js";

const FETCH_TIMEOUT_MS = 8000;
const PER_PAGE_HTML_CAP = 250_000;
const PER_PAGE_TEXT_CAP = 4_000; // post-strip
const MAX_PAGES = 8;

const CANDIDATE_PATTERNS = [
  // Path-name patterns we try first. Order = collection priority (one of each
  // kind is taken). First capture group names the `kind`.
  /\b(about|story|mission|who-we-are)\b/i,
  /\b(values|sustainability|responsibility|impact|ethos|craft|heritage)\b/i,
  /\b(press|news|newsroom|media)\b/i,
  /\b(journal|blog|stories|magazine)\b/i,
  /\b(faq|faqs|help|support|questions)\b/i,
  /\b(shipping|delivery)\b/i,
  /\b(returns?|exchanges?|refunds?|warranty|guarantee)\b/i,
  /\b(products?|shop|catalog|collection)\b/i,
  /\b(careers|company|team)\b/i,
];

export interface PageContent {
  url: string;
  path: string;
  /** Section type inferred from path / link text — "about" | "press" | etc. */
  kind: string;
  title?: string;
  text: string;
  /** Word count of stripped text (zero = page returned empty or 404). */
  word_count: number;
}

export interface MultiPageHarvest {
  /** Pages we tried to fetch (may include failures with text=""). */
  pages: PageContent[];
  /** Total stripped text bytes across all pages. */
  total_text_bytes: number;
  errors: string[];
}

/**
 * Fetch a sample of brand-voice-bearing pages from the same domain.
 * Pass `homepageHtml` if you've already scraped it — saves a roundtrip.
 */
export async function harvestMultiPage(args: {
  domain: string;
  homepageHtml?: string;
  browser?: Fetcher;
}): Promise<MultiPageHarvest> {
  const out: MultiPageHarvest = { pages: [], total_text_bytes: 0, errors: [] };

  let html = args.homepageHtml;
  if (!html) {
    try {
      html = await fetchCappedWithBrowserFallback(`https://${args.domain}/`, PER_PAGE_HTML_CAP, args.browser);
    } catch (e) {
      out.errors.push(`homepage: ${(e as Error).message}`);
      return out;
    }
  }
  // If we were handed a tiny stub (likely bot-blocked) and have a browser
  // binding, re-render via CF Browser Rendering before mining links.
  if (html.length < 2_000 && args.browser) {
    try {
      const rendered = await fetchViaBrowser(args.browser, `https://${args.domain}/`);
      if (rendered.length > html.length) html = rendered;
    } catch (e) {
      out.errors.push(`homepage browser: ${(e as Error).message}`);
    }
  }

  // Collect candidate URLs from <a> hrefs, keep same-origin only.
  const candidates = pickCandidates(html, args.domain);

  // Fetch up to MAX_PAGES in parallel. Each falls back to browser if direct
  // fetch returns < 2KB (bot wall).
  const fetched = await Promise.allSettled(
    candidates.slice(0, MAX_PAGES).map(async (c) => {
      const html = await fetchCappedWithBrowserFallback(c.url, PER_PAGE_HTML_CAP, args.browser);
      return { c, html };
    }),
  );

  for (const r of fetched) {
    if (r.status === "rejected") {
      out.errors.push((r.reason as Error).message);
      continue;
    }
    const { c, html } = r.value;
    const title = extractTitle(html);
    const text = stripToText(html).slice(0, PER_PAGE_TEXT_CAP);
    const pc: PageContent = {
      url: c.url,
      path: c.path,
      kind: c.kind,
      title,
      text,
      word_count: text.trim() ? text.trim().split(/\s+/).length : 0,
    };
    out.pages.push(pc);
    out.total_text_bytes += text.length;
  }

  return out;
}

interface Candidate {
  url: string;
  path: string;
  kind: string;
}

function pickCandidates(html: string, domain: string): Candidate[] {
  const out: Candidate[] = [];
  const seenPath = new Set<string>();
  const baseUrl = `https://${domain}`;
  const linkRe = /<a[^>]+href=["']([^"'#?]+)[^"']*["'][^>]*>([\s\S]*?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = linkRe.exec(html)) !== null) {
    const href = m[1]!;
    const linkText = stripToText(m[2]!).trim().slice(0, 100);
    let url: URL;
    try { url = new URL(href, baseUrl); } catch { continue; }
    const host = url.hostname.replace(/^www\./, "");
    const want = domain.replace(/^www\./, "");
    if (host !== want) continue;
    const path = url.pathname.replace(/\/$/, "");
    if (!path || path === "/" || seenPath.has(path)) continue;

    // Score by pattern match against path + link text.
    let kind: string | null = null;
    // A deep `/products/<handle>` (or `/product/<handle>`) is a full PDP — the
    // richest copy source for product voice. Recognize it distinctly from the
    // shop/collection landing page so we always grab one real PDP.
    if (/\/products?\/[^/]+/i.test(path) && !/\/products?\/?$/i.test(path)) {
      kind = "full-pdp";
    } else {
      for (const pat of CANDIDATE_PATTERNS) {
        if (pat.test(path) || pat.test(linkText)) {
          kind = pat.source.match(/\(([^)|]+)/)?.[1] ?? "other";
          break;
        }
      }
    }
    if (!kind) continue;
    seenPath.add(path);
    out.push({ url: url.toString(), path, kind });
    if (out.length >= MAX_PAGES * 3) break; // collect a bit more than needed; we'll filter
  }

  // Prefer one of each kind: about, values, press, journal, faq, shipping,
  // returns, products, careers, full-pdp.
  const byKind = new Map<string, Candidate>();
  for (const c of out) {
    if (!byKind.has(c.kind)) byKind.set(c.kind, c);
  }
  return Array.from(byKind.values()).slice(0, MAX_PAGES);
}

function extractTitle(html: string): string | undefined {
  return html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.trim().replace(/\s+/g, " ").slice(0, 200);
}

/** Crude but effective: drop scripts/styles/nav/footer, then strip tags. */
function stripToText(html: string): string {
  let s = html;
  s = s.replace(/<script[\s\S]*?<\/script>/gi, "");
  s = s.replace(/<style[\s\S]*?<\/style>/gi, "");
  s = s.replace(/<noscript[\s\S]*?<\/noscript>/gi, "");
  s = s.replace(/<svg[\s\S]*?<\/svg>/gi, "");
  s = s.replace(/<(?:nav|footer|aside|header)[\s\S]*?<\/(?:nav|footer|aside|header)>/gi, "");
  s = s.replace(/<[^>]+>/g, " ");
  s = s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
  s = s.replace(/\s+/g, " ").trim();
  return s;
}

async function fetchCappedWithBrowserFallback(url: string, maxBytes: number, browser?: Fetcher): Promise<string> {
  let html: string;
  try {
    html = await fetchCapped(url, maxBytes);
  } catch (e) {
    if (!browser) throw e;
    return fetchViaBrowser(browser, url);
  }
  if (html.length < 2_000 && browser) {
    try {
      const rendered = await fetchViaBrowser(browser, url);
      if (rendered.length > html.length) return rendered;
    } catch { /* fall through with the small html */ }
  }
  return html;
}

// CF Browser Rendering via the shared scrape/browser.ts renderPage() (real
// env.BROWSER binding) — replaces the old fictional
// `https://browser-rendering.cf/v1/content` host. Throws on failure so the
// caller keeps the small-but-real direct HTML.
async function fetchViaBrowser(browser: Fetcher, url: string): Promise<string> {
  const r = await renderPage({ BROWSER: browser } as Bindings, url, { waitMs: 0 });
  if (!r.ok || r.html === undefined) {
    throw new Error(`browser render failed: ${r.error ?? "no_html"}`);
  }
  return r.html.length > PER_PAGE_HTML_CAP ? r.html.slice(0, PER_PAGE_HTML_CAP) : r.html;
}

async function fetchCapped(url: string, maxBytes: number): Promise<string> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    // Shared realistic Chrome fingerprint — avoids WAF blocks on brand sites.
    const r = await fetch(url, {
      headers: browserHeaders(),
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const text = await r.text();
    return text.length > maxBytes ? text.slice(0, maxBytes) : text;
  } finally {
    clearTimeout(t);
  }
}
