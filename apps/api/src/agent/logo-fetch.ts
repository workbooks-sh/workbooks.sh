// Domain-agnostic logo cascade. Tries each source in order; first valid hit
// wins. Validates every candidate (HTTP 200, image content-type, >1KB) so
// the book never ships an empty or broken logo_url.
//
// Wavelet's v3* postmortem flagged this: 0 of 8 runs got a usable logo.
// This module is the fix — works without any vendor API keys (Clearbit and
// the brand's own site favicon/og-image are free).

export interface LogoResult {
  url: string;
  source: "clearbit" | "logo-dev" | "apple-touch-icon" | "favicon" | "og-image" | "link-icon";
  content_type: string;
  bytes: number | null;
}

export interface LogoFetchOutcome {
  result: LogoResult | null;
  attempts: Array<{ source: string; url: string; ok: boolean; reason?: string }>;
}

const MIN_BYTES = 512; // sub-512 byte responses are almost always 1×1 pixels or empty placeholders
const FETCH_TIMEOUT_MS = 6000;

// A favicon / app-icon is NOT a logo. tecovas.com resolved to favicon.svg and
// shipped a raw favicon as PRIMARY_URL because the cascade accepted the first
// passing image — including favicon.ico / a <link rel=icon> SVG. These URLs
// are recognised by filename and rejected as the *recommended* logo: a brand
// book must carry a real wordmark/logo or honestly record needs_data, never a
// 16-32px browser tab glyph.
const FAVICON_URL_RE =
  /(?:^|\/)(?:favicon(?:[-.]\w+)?\.(?:ico|svg|png|gif)|favicon|apple-touch-icon(?:-precomposed)?(?:-\d+x\d+)?\.png|mstile[-\w]*\.png|safari-pinned-tab\.svg|android-chrome-\d+x\d+\.png)(?:[?#]|$)/i;

/** True when the URL's filename is a browser favicon / OS app-icon — i.e. a
 *  tab glyph, not a brand logo. Pattern-based so it fires even when we have no
 *  dimensions (a dimensionless SVG favicon supplies no aspect signal). */
export function isFaviconUrl(url: string): boolean {
  try {
    const path = new URL(url).pathname;
    return FAVICON_URL_RE.test(path);
  } catch {
    return FAVICON_URL_RE.test(url);
  }
}

async function probe(url: string): Promise<{ ok: boolean; content_type?: string; bytes?: number | null; reason?: string }> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    // HEAD first (cheap), fall back to GET if HEAD not allowed.
    let r = await fetch(url, { method: "HEAD", redirect: "follow", signal: ctrl.signal });
    if (r.status === 405 || r.status === 501) {
      r = await fetch(url, { method: "GET", redirect: "follow", signal: ctrl.signal });
    }
    if (!r.ok) return { ok: false, reason: `http_${r.status}` };
    const ct = (r.headers.get("content-type") ?? "").toLowerCase();
    if (!ct.startsWith("image/")) return { ok: false, reason: `not_image_${ct.slice(0, 30)}` };
    const len = parseInt(r.headers.get("content-length") ?? "0", 10);
    if (len > 0 && len < MIN_BYTES) return { ok: false, reason: `too_small_${len}b` };
    return { ok: true, content_type: ct, bytes: len || null };
  } catch (e) {
    return { ok: false, reason: (e as Error).name === "AbortError" ? "timeout" : (e as Error).message };
  } finally {
    clearTimeout(t);
  }
}

async function scrapeHomepageMetaImage(domain: string): Promise<{ ogImage?: string; iconUrl?: string }> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(`https://${domain}/`, {
      headers: { "user-agent": "Mozilla/5.0 (compatible; brandnana-bot/1.0)" },
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (!r.ok) return {};
    const html = (await r.text()).slice(0, 200_000); // cap at 200KB
    const og = html.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)?.[1]
      ?? html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i)?.[1];
    const icon = html.match(/<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)["']/i)?.[1]
      ?? html.match(/<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*icon[^"']*["']/i)?.[1];
    return {
      ogImage: og ? new URL(og, `https://${domain}`).toString() : undefined,
      iconUrl: icon ? new URL(icon, `https://${domain}`).toString() : undefined,
    };
  } catch {
    return {};
  } finally {
    clearTimeout(t);
  }
}

export async function fetchLogo(
  domain: string,
  opts: { logoDevToken?: string } = {},
): Promise<LogoFetchOutcome> {
  const attempts: LogoFetchOutcome["attempts"] = [];

  const tryUrl = async (
    url: string,
    source: LogoResult["source"],
  ): Promise<LogoResult | null> => {
    const p = await probe(url);
    // A favicon-named asset is recorded as a rejected attempt, never a logo —
    // even if it probes ok — so it can never become the recommended result.
    if (p.ok && isFaviconUrl(url)) {
      attempts.push({ source, url, ok: false, reason: "rejected_favicon_or_app_icon" });
      return null;
    }
    attempts.push({ source, url, ok: p.ok, reason: p.reason });
    if (!p.ok) return null;
    return { url, source, content_type: p.content_type ?? "image/*", bytes: p.bytes ?? null };
  };

  // 1. Clearbit — free public logos, very high hit rate for known brands.
  let r = await tryUrl(`https://logo.clearbit.com/${domain}`, "clearbit");
  if (r) return { result: r, attempts };

  // 2. logo.dev (now context.dev) — needs token. Only attempt if present.
  if (opts.logoDevToken) {
    r = await tryUrl(`https://img.logo.dev/${domain}?token=${opts.logoDevToken}&format=svg`, "logo-dev");
    if (r) return { result: r, attempts };
    r = await tryUrl(`https://img.logo.dev/${domain}?token=${opts.logoDevToken}`, "logo-dev");
    if (r) return { result: r, attempts };
  }

  // 3. Scrape homepage HTML for <meta og:image> or <link rel="icon">. og:image
  // is a real social-share image (a logo/hero), not a favicon, so it ranks
  // ABOVE the on-disk icon probes. A <link rel=icon> href is a favicon and is
  // gated by isFaviconUrl below — it is tried only to record the attempt, and
  // tryUrl rejects it if it is favicon-named.
  const meta = await scrapeHomepageMetaImage(domain);
  if (meta.ogImage) {
    r = await tryUrl(meta.ogImage, "og-image");
    if (r) return { result: r, attempts };
  }

  // 4. Site's own apple-touch-icon (usually 180×180 high-quality PNG). This is
  // an OS app icon, not a logo — accepted ONLY as a last-resort square glyph
  // when no real logo source resolved, and only if it is not favicon-named
  // (apple-touch-icon.png IS favicon-named per FAVICON_URL_RE, so these are
  // rejected too; the probe runs to record an honest attempt).
  r = await tryUrl(`https://${domain}/apple-touch-icon.png`, "apple-touch-icon");
  if (r) return { result: r, attempts };
  r = await tryUrl(`https://${domain}/apple-touch-icon-precomposed.png`, "apple-touch-icon");
  if (r) return { result: r, attempts };

  // 5. Site's favicon.ico / <link rel=icon>. ALWAYS favicon-named, so tryUrl
  // rejects these as the recommended logo — we still probe them so the
  // provenance honestly records "favicon present but rejected" rather than a
  // silent miss.
  await tryUrl(`https://${domain}/favicon.ico`, "favicon");
  if (meta.iconUrl) {
    await tryUrl(meta.iconUrl, "link-icon");
  }

  // Nothing but favicons/app-icons resolved — return result:null so callers
  // record this as honest needs_data (no logo), NEVER a raw favicon.
  return { result: null, attempts };
}
