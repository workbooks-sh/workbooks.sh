// POST /v1/book/render-slides — VISUAL-REVIEW gate.
//
// Renders a PUBLISHED brand-book deck to per-slide PNG images so the strategist
// agent can SEE each slide (not just the deck source) and self-correct.
//
// Auth: existing bearer (same as the rest of /v1/book).
//
// Request body (one of):
//   { slug }   — resolves to the public deck https://api.brandnana.net/books/<slug>.html
//   { url }    — an absolute https URL of a served deck (must be a brandnana host)
// Optional:
//   { max_slides }  — cap (default 60, clamped [1,200])
//
// Response on success:
//   { slug, deck_url, total, truncated, defect_count,
//     slides: [{ index, key, url, defects: [{ type, detail }] }] }
//
// `defects` are DETERMINISTIC mechanical faults (overflow / clipping / empty /
// broken-image) measured in-browser at render time — NO LLM. `defect_count` is
// the total across all slides; deck-gate.sh fails on any hard defect.
//
// Each slide PNG is mirrored into the ASSETS R2 bucket via storeBytesToR2 (the
// same sha256-deduped /assets/<sha>.png path used for screenshots), so the
// per-slide images are self-hosted, world-readable, and survive forever.
//
// Fail-soft: renderDeckSlides never throws and returns partial results; this
// route surfaces a 502 only when NOTHING rendered, otherwise returns the slides
// that did render plus a `warning` for any partial failure.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { renderDeckSlides } from "../scrape/browser.js";
import { storeBytesToR2 } from "../mirror/routes.js";

const renderSlides = new Hono<{ Bindings: Bindings }>();
renderSlides.use("*", requireBearer);

// Canonical public deck base. Decks are served by book/serve.ts at
// GET /books/<slug>.html out of the SAME worker, so we point the headless
// browser at api.brandnana.net (or the MIRROR_ASSET_BASE override host).
const DEFAULT_DECK_BASE = "https://api.brandnana.net";

const SLUG_RE = /^[a-z0-9_-]+$/i;
// Only render decks served by a brandnana host — never an arbitrary URL (SSRF).
const ALLOWED_HOST_RE = /(^|\.)brandnana\.net$/i;

const MAX_SLIDES_CAP = 60;

function deckBase(env: Bindings): string {
  const raw = env.MIRROR_ASSET_BASE?.trim();
  if (raw && /^https:\/\/[a-z0-9.-]+(?::\d+)?$/i.test(raw.replace(/\/+$/, ""))) {
    return raw.replace(/\/+$/, "");
  }
  return DEFAULT_DECK_BASE;
}

/** Resolve the request to a { slug, url } deck target, or an error string. */
function resolveDeck(
  env: Bindings,
  body: { slug?: string; url?: string },
): { slug: string; url: string } | { error: string } {
  // Explicit URL wins, but must be an https brandnana host pointing at a book.
  if (typeof body.url === "string" && body.url.length > 0) {
    let u: URL;
    try {
      u = new URL(body.url);
    } catch {
      return { error: "invalid_url" };
    }
    if (u.protocol !== "https:") return { error: "url_must_be_https" };
    if (!ALLOWED_HOST_RE.test(u.hostname)) return { error: "url_host_not_allowed" };
    // Derive a slug from the path for naming the R2 keys: /books/<slug>.html
    const m = /\/books\/([a-z0-9_-]+)\.html$/i.exec(u.pathname);
    const slug =
      m?.[1] ??
      (u.pathname.replace(/[^a-z0-9_-]+/gi, "-").replace(/^-+|-+$/g, "") || "deck");
    return { slug, url: u.toString() };
  }

  if (typeof body.slug === "string" && SLUG_RE.test(body.slug)) {
    const slug = body.slug.toLowerCase();
    return { slug, url: `${deckBase(env)}/books/${slug}.html` };
  }

  return { error: "missing_slug_or_url" };
}

renderSlides.post("/", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    slug?: string;
    url?: string;
    max_slides?: number;
  };

  const target = resolveDeck(c.env, body);
  if ("error" in target) {
    return c.json(
      { error: target.error, message: "provide { slug } or a brandnana { url } of a served deck" },
      400,
    );
  }

  const maxSlides =
    typeof body.max_slides === "number" && Number.isFinite(body.max_slides)
      ? body.max_slides
      : MAX_SLIDES_CAP;

  const result = await renderDeckSlides(c.env, target.url, { maxSlides });

  if (!result.ok || result.slides.length === 0) {
    return c.json(
      {
        error: "render_failed",
        slug: target.slug,
        deck_url: target.url,
        message: result.error ?? "no slides rendered",
      },
      502,
    );
  }

  // Mirror each PNG to R2 (sha256-deduped /assets/<sha>.png). Done in order so
  // the returned `slides` array preserves slide order.
  const safeSlug = target.slug.replace(/[^a-z0-9_-]+/gi, "-").toLowerCase();
  const slides: Array<{
    index: number;
    key: string;
    url: string;
    defects: Array<{ type: string; detail: string }>;
  }> = [];
  const mirrorErrors: string[] = [];

  for (const s of result.slides) {
    const r2 = await storeBytesToR2(c.env, new Uint8Array(s.png), {
      contentType: "image/png",
      sourceUrl: `${target.url}#${s.key}`,
    });
    if (r2) {
      slides.push({ index: s.index, key: s.key, url: r2, defects: s.defects });
    } else {
      mirrorErrors.push(`${s.index}:${s.key}`);
    }
  }

  if (slides.length === 0) {
    return c.json(
      {
        error: "mirror_failed",
        slug: safeSlug,
        deck_url: target.url,
        message: "rendered slides but could not mirror any PNG to R2",
      },
      502,
    );
  }

  const warning =
    [result.error, mirrorErrors.length ? `mirror_failed:${mirrorErrors.join(",")}` : ""]
      .filter(Boolean)
      .join("; ") || undefined;

  const defectCount = slides.reduce((n, s) => n + s.defects.length, 0);

  return c.json({
    ok: true,
    slug: safeSlug,
    deck_url: target.url,
    total: result.total ?? result.slides.length,
    truncated: result.truncated ?? false,
    count: slides.length,
    defect_count: defectCount,
    slides,
    ...(warning ? { warning } : {}),
  });
});

export default renderSlides;
