// Brand screenshot capture + R2 mirroring.
//
// Two layers live here:
//
//   1. The legacy synchronous helpers `screenshotUrl()` / `homepageScreenshot()`
//      build a WordPress mshots URL. mshots is free + no-auth but is the WEAKEST
//      tier: it returns a placeholder on first call and 403s with a realistic
//      Chrome UA. Kept for backward-compat callers (executor / concept-deck /
//      pipeline) that just need a best-effort hot-link.
//
//   2. The robust async `captureScreenshot()` cascade (Stage-1 harvester). It
//      makes context.dev's WORKING hosted PNG endpoint the PRIMARY capture,
//      then escalates through CF Browser Rendering (scrape/browser.renderPage)
//      -> Firecrawl screenshot -> mshots, and MIRRORS the winning bytes to R2
//      so the book substrate is self-hosted + deduped. It NEVER returns a bare
//      hot-link: every success carries an https://api.brandnana.net/assets/<sha>
//      URL. On total failure it returns { ok:false, error } (fail loud).
//
// Design: docs/audit/BRAND-DATA-HARVEST.md P1 #8.

import type { Bindings } from "../env.js";
import { getScreenshot } from "../scrape/context.js";
import { renderPage } from "../scrape/browser.js";
import { firecrawlScrape } from "../scrape/firecrawl.js";
import { mirrorToR2, storeBytesToR2 } from "../mirror/routes.js";

export interface Screenshot {
  url: string;
  source: "mshots";
  viewport: { width: number; height: number };
}

export function screenshotUrl(siteUrl: string, opts: { width?: number; height?: number } = {}): Screenshot {
  const width = opts.width ?? 1280;
  const height = opts.height ?? 800;
  const encoded = encodeURIComponent(siteUrl);
  return {
    url: `https://s.wordpress.com/mshots/v1/${encoded}?w=${width}&h=${height}`,
    source: "mshots",
    viewport: { width, height },
  };
}

/** Convenience: build the homepage mshots screenshot URL for a bare domain. */
export function homepageScreenshot(domain: string, opts: { width?: number; height?: number } = {}): Screenshot {
  return screenshotUrl(`https://${domain}/`, opts);
}

// ── Robust capture cascade ──────────────────────────────────────────────────

/** Capture variants. viewport = 1280x800 above-the-fold; fullpage = full
 *  scrolled page; mobile = a phone viewport (390x844). */
export type CaptureKind = "viewport" | "fullpage" | "mobile";

export interface CaptureScreenshotArgs {
  domain: string;
  /** default "viewport" */
  kind?: CaptureKind;
  tenant: string;
  ctx?: ExecutionContext;
}

export interface CaptureScreenshotResult {
  /** true only when a screenshot was captured AND mirrored to R2. */
  ok: boolean;
  /** https://api.brandnana.net/assets/<sha>.<ext> — present iff ok. */
  r2_url?: string;
  /** which rung of the cascade won (or the last rung tried on failure). */
  source: string;
  /** present iff !ok — every attempt's failure, comma-joined (fail loud). */
  error?: string;
}

const VIEWPORTS: Record<CaptureKind, { width: number; height: number; fullPage: boolean }> = {
  viewport: { width: 1280, height: 800, fullPage: false },
  fullpage: { width: 1280, height: 800, fullPage: true },
  mobile: { width: 390, height: 844, fullPage: false },
};

function pageUrl(domain: string): string {
  const d = domain.replace(/^https?:\/\//, "").replace(/\/+$/, "");
  return `https://${d}/`;
}

/**
 * Capture a screenshot of a brand's homepage and mirror the bytes to R2.
 *
 * Cascade (each rung verified, escalates on failure — never silent-empty):
 *   1. context.dev getScreenshot — returns a hosted 1920x1080 PNG URL (the
 *      WORKING primary, live-proven). Mirror that URL's bytes to R2.
 *   2. CF Browser Rendering renderPage({ screenshot:true }) — real headless
 *      Chromium bytes for the requested viewport/fullpage/mobile. Store to R2.
 *   3. Firecrawl screenshot — JS-rendered fallback for the hardest sites;
 *      returns a hosted URL we then mirror to R2.
 *   4. mshots (tertiary) — free hot-link; mirror its bytes to R2.
 *
 * context.dev (rung 1) always yields a viewport/fullpage PNG regardless of
 * `kind`, so for kind="mobile" / "fullpage" we lead with renderPage (rung 2)
 * which honors the requested viewport, then fall back to context.dev.
 */
export async function captureScreenshot(
  env: Bindings,
  args: CaptureScreenshotArgs,
): Promise<CaptureScreenshotResult> {
  const kind: CaptureKind = args.kind ?? "viewport";
  const vp = VIEWPORTS[kind];
  const url = pageUrl(args.domain);
  const errors: string[] = [];

  // For viewport captures, context.dev's hosted PNG is the cheapest reliable
  // primary. For mobile/fullpage, renderPage honors the viewport, so try it
  // first and demote context.dev to a fallback.
  const order: Array<"context" | "browser" | "firecrawl" | "mshots"> =
    kind === "viewport"
      ? ["context", "browser", "firecrawl", "mshots"]
      : ["browser", "context", "firecrawl", "mshots"];

  for (const rung of order) {
    try {
      if (rung === "context") {
        const shot = await getScreenshot(env, args.domain, args.tenant, args.ctx);
        const hosted = shot?.screenshot;
        if (!hosted || !/^https?:\/\//.test(hosted)) {
          errors.push("context:no-url");
          continue;
        }
        const r2 = await mirrorToR2(env, hosted, args.ctx);
        if (r2) return { ok: true, r2_url: r2, source: "context-dev" };
        errors.push("context:mirror-failed");
        continue;
      }

      if (rung === "browser") {
        const r = await renderPage(env, url, {
          screenshot: true,
          fullPage: vp.fullPage,
          waitMs: 1500,
        });
        if (!r.ok || !r.screenshot) {
          errors.push(`browser:${r.error ?? "no-bytes"}`);
          continue;
        }
        const r2 = await storeBytesToR2(env, new Uint8Array(r.screenshot), {
          contentType: "image/png",
          sourceUrl: url,
        });
        if (r2) return { ok: true, r2_url: r2, source: "cf-browser" };
        errors.push("browser:mirror-failed");
        continue;
      }

      if (rung === "firecrawl") {
        const fc = await firecrawlScrape(env, {
          url,
          formats: ["screenshot"],
          tenant: args.tenant,
          ctx: args.ctx,
        });
        // Firecrawl returns a hosted screenshot URL on data.screenshot.
        const hosted = (fc.data as { screenshot?: string } | undefined)?.screenshot;
        if (!fc.success || !hosted || !/^https?:\/\//.test(hosted)) {
          errors.push(`firecrawl:${fc.error ?? "no-url"}`);
          continue;
        }
        const r2 = await mirrorToR2(env, hosted, args.ctx);
        if (r2) return { ok: true, r2_url: r2, source: "firecrawl" };
        errors.push("firecrawl:mirror-failed");
        continue;
      }

      // mshots (tertiary): free hot-link, mirror its bytes.
      const ms = screenshotUrl(url, { width: vp.width, height: vp.height });
      const r2 = await mirrorToR2(env, ms.url, args.ctx);
      if (r2) return { ok: true, r2_url: r2, source: "mshots" };
      errors.push("mshots:mirror-failed");
    } catch (e) {
      errors.push(`${rung}:${e instanceof Error ? e.message : String(e)}`);
    }
  }

  return {
    ok: false,
    source: order[order.length - 1] ?? "mshots",
    error: errors.join("; ") || "all screenshot tiers failed",
  };
}
