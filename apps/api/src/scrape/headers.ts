// Shared realistic-browser request headers.
//
// Many brand marketing sites bot-block obvious crawler User-Agents at the WAF.
// We are scraping PUBLIC marketing pages, not private data — matching a real,
// current Chrome desktop fingerprint is necessary to get past those walls.
//
// Centralized here so every fetcher (direct tier in fetch-brand.ts,
// homepage-scrape.ts, multipage-text.ts, asset-probe.ts, …) shares ONE
// compliant UA. Bumping Chrome here updates all of them.

/** Realistic current Chrome desktop User-Agent (Chrome 137, macOS). */
export const BROWSER_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36";

/**
 * Build a realistic browser request header set (UA + Accept + Accept-Language
 * + the Client-Hint / Sec-Fetch fingerprint a real Chrome sends).
 *
 * @param extra Per-call overrides / additions (e.g. a narrower Accept for CSS
 *              or images). Keys here win over the defaults.
 */
export function browserHeaders(extra?: Record<string, string>): Record<string, string> {
  const base: Record<string, string> = {
    "user-agent": BROWSER_UA,
    accept:
      "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "accept-language": "en-US,en;q=0.9",
    "accept-encoding": "gzip, deflate, br",
    "sec-ch-ua": '"Google Chrome";v="137", "Chromium";v="137", "Not/A)Brand";v="24"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"macOS"',
    "sec-fetch-dest": "document",
    "sec-fetch-mode": "navigate",
    "sec-fetch-site": "none",
    "sec-fetch-user": "?1",
    "upgrade-insecure-requests": "1",
  };
  return extra ? { ...base, ...extra } : base;
}
