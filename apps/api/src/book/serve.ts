// /books/* — serve brand-book .html files from R2.
//
// Two visibility tiers:
//
//   public:   GET /books/<slug>.html          → R2 brand-books/public/<slug>.html
//             - No auth, anyone-can-load.
//             - Cache-Control: public, max-age=3600 (browser + CF edge cache).
//             - Used by the lander iframe and by anyone with the direct URL.
//
//   private:  GET /books/private/<slug>.html  → R2 brand-books/private/<account_id>/<slug>.html
//             - Requires Authorization: Bearer <api-key>.
//             - account_id from auth check must match the book's path segment.
//             - Cache-Control: private, no-cache.
//
// The actual write side lives in routes.ts (POST /v1/book/seed/:slug for
// public, POST /v1/book for private).

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";

const serve = new Hono<{ Bindings: Bindings }>();

const SLUG_RE = /^[a-z0-9_-]+\.html$/i;

function bookSlugIfValid(name: string | undefined): string | null {
  if (!name) return null;
  if (!SLUG_RE.test(name)) return null;
  return name.slice(0, -5); // strip .html
}

// ── Public ───────────────────────────────────────────────────────────────────

serve.get("/:filename", async (c) => {
  const slug = bookSlugIfValid(c.req.param("filename"));
  if (!slug) return c.json({ error: "invalid_book" }, 400);

  const key = `brand-books/public/${slug}.html`;
  const obj = await c.env.ASSETS.get(key);
  if (!obj) return c.text(`Book not found: ${slug}`, 404);

  return new Response(obj.body, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=3600, s-maxage=86400",
      "x-brandnana-book-slug": slug,
      "x-brandnana-book-visibility": "public",
      // Allow iframe embed from any origin — public books are designed for it.
      "content-security-policy": "frame-ancestors *",
    },
  });
});

// ── Private ──────────────────────────────────────────────────────────────────

const priv = new Hono<{ Bindings: Bindings }>();
priv.use("*", requireBearer);

priv.get("/:filename", async (c) => {
  const slug = bookSlugIfValid(c.req.param("filename"));
  if (!slug) return c.json({ error: "invalid_book" }, 400);

  const user = c.get("user");
  const key = `brand-books/private/${user.id}/${slug}.html`;
  const obj = await c.env.ASSETS.get(key);
  if (!obj) return c.text(`Book not found in your account: ${slug}`, 404);

  return new Response(obj.body, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "private, no-cache",
      "x-brandnana-book-slug": slug,
      "x-brandnana-book-visibility": "private",
    },
  });
});

serve.route("/private", priv);

export default serve;

// ── Concept-images serving (sibling route mounted at /concept-images/*) ─────

import type { Hono as HonoT } from "hono";

export const conceptImages = new Hono<{ Bindings: Bindings }>();

// Slug + filename. Filename can be "<digit>.png" (older) OR "<ref>-<digit>.png"
// / "<ref>.png" (current). Allow any [a-z0-9_-]+ for both parts.
const IMG_PATH_RE = /^[a-z0-9_-]+\/[a-z0-9_-]+\.(?:png|jpg|jpeg|webp|gif)$/i;

conceptImages.get("/:slug/:filename", async (c) => {
  const slug = c.req.param("slug");
  const filename = c.req.param("filename");
  const path = `${slug}/${filename}`;
  if (!IMG_PATH_RE.test(path)) return c.json({ error: "invalid_image_path" }, 400);

  // Edge cache: first hit fetches from R2 + writes to cache; subsequent hits
  // return from CF's edge cache in ~10-20ms instead of 100-300ms from R2.
  // The `cf-cache-status` header on responses tells us whether this fired.
  const cache = (caches as any).default as Cache;
  const cacheKey = new Request(c.req.url, { method: "GET" });
  const hit = await cache.match(cacheKey);
  if (hit) {
    const headers = new Headers(hit.headers);
    headers.set("x-brandnana-cache", "HIT");
    return new Response(hit.body, { status: hit.status, headers });
  }

  const key = `concept-images/${path}`;
  const obj = await c.env.ASSETS.get(key);
  if (!obj) return c.text(`Image not found: ${path}`, 404);
  const ext = filename.split(".").pop()!.toLowerCase();
  const ct = ext === "png" ? "image/png" : ext === "jpg" || ext === "jpeg" ? "image/jpeg" : ext === "webp" ? "image/webp" : "image/gif";

  // R2 objects have known length — set Content-Length so the browser knows
  // how much to preallocate (also makes some CDN paths happier).
  const headers = new Headers({
    "content-type": ct,
    "cache-control": "public, max-age=31536000, immutable",
    "content-security-policy": "frame-ancestors *",
    "x-brandnana-cache": "MISS",
  });
  if (obj.size) headers.set("content-length", String(obj.size));

  // Tee the body so we can return one stream + cache the other.
  const [forClient, forCache] = obj.body!.tee();
  const cacheResp = new Response(forCache, { status: 200, headers: new Headers(headers) });
  c.executionCtx.waitUntil(cache.put(cacheKey, cacheResp));
  return new Response(forClient, { status: 200, headers });
});
