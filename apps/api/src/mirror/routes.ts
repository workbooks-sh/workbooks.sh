// Image mirroring to R2.
//
// /assets/<sha256>.<ext>  — public read of a mirrored image
// POST /mirror/images { urls: [...] } — fetch each url, sha256 the
//   bytes, put to R2 (skip if already there), return
//   { mapping: { original_url: mirrored_url } }
//
// Dedup is global (one hash → one R2 object) across brands, so two
// brands using the same Shopify CDN image only pay storage once.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { browserHeaders } from "../scrape/headers.js";

const mirror = new Hono<{ Bindings: Bindings }>();

/** Canonical public base that serves /assets/<sha> out of the ASSETS R2
 *  bucket. The GET /assets/:filename route below is mounted at the worker
 *  root and the custom domain api.brandnana.net points at the SAME worker /
 *  R2 bucket as the *.workers.dev default host, so this canonical base owns
 *  every mirrored URL regardless of which host actually served the request.
 *  Pinning it here (never deriving from the request) keeps the substrate's
 *  media URLs stable and matches the validator regex
 *  ^https://api\.brandnana\.net/assets/… */
export const ASSETS_PUBLIC_BASE = "https://api.brandnana.net";

/** Resolve the canonical asset base: the MIRROR_ASSET_BASE env override (if a
 *  valid https URL) else the hardcoded canonical base. The request host is
 *  NEVER consulted — that is exactly the bug that leaked
 *  brandnana-api.shane-6d4.workers.dev into the substrate. */
function canonicalAssetBase(env: Bindings): string {
  const raw = env.MIRROR_ASSET_BASE?.trim();
  if (raw && /^https:\/\/[a-z0-9.-]+(?::\d+)?$/i.test(raw.replace(/\/+$/, ""))) {
    return raw.replace(/\/+$/, "");
  }
  return ASSETS_PUBLIC_BASE;
}

const MAX_URLS_PER_CALL = 50;
const MAX_BYTES_PER_IMAGE = 8 * 1024 * 1024; // 8 MiB
const FETCH_TIMEOUT_MS = 10_000;

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function extFromContentType(ct: string | null | undefined, url: string): string {
  const sub = (ct ?? "").split("/")[1]?.split(";")[0]?.trim();
  if (sub === "jpeg") return "jpg";
  if (sub && /^[a-z0-9]+$/.test(sub)) return sub;
  // fall back to URL extension
  const m = /\.([a-zA-Z0-9]{2,5})(?:\?|$)/.exec(url);
  return (m?.[1] ?? "bin").toLowerCase();
}

async function fetchBytes(
  url: string,
): Promise<{ bytes: Uint8Array; contentType: string | null } | null> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    // Realistic browser headers: image CDNs (brand.dev, mshots, Shopify) and
    // WAFs hot-link-block / 403 a bare default UA.
    const r = await fetch(url, {
      signal: ctrl.signal,
      redirect: "follow",
      headers: browserHeaders({ accept: "image/avif,image/webp,image/png,image/*,*/*;q=0.8" }),
    });
    if (!r.ok) return null;
    const buf = await r.arrayBuffer();
    if (buf.byteLength > MAX_BYTES_PER_IMAGE) return null;
    return { bytes: new Uint8Array(buf), contentType: r.headers.get("content-type") };
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

function publicAssetUrl(key: string, base: string): string {
  // Served by GET /assets/:filename below. `base` is ALWAYS the canonical
  // asset base (api.brandnana.net or MIRROR_ASSET_BASE) — never the request
  // host — so links are stable and pass the substrate validator.
  return `${base}/assets/${key}`;
}

/** Store raw bytes in the ASSETS R2 bucket under images/<sha>.<ext> with
 *  sha256 dedup, returning the canonical https://api.brandnana.net/assets/<sha>.<ext>
 *  URL (or the MIRROR_ASSET_BASE override). Used by mirrorToR2() and the
 *  screenshot capture cascade so a freshly rendered screenshot (which has no
 *  source URL) can be mirrored too. The host is pinned to the canonical base
 *  derived from `env` — there is no way for a caller to inject the request
 *  host. */
export async function storeBytesToR2(
  env: Bindings,
  bytes: Uint8Array,
  opts?: { contentType?: string | null; sourceUrl?: string },
): Promise<string | null> {
  try {
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_BYTES_PER_IMAGE) return null;
    const hash = await sha256Hex(bytes);
    const ext = extFromContentType(opts?.contentType, opts?.sourceUrl ?? "");
    const filename = `${hash}.${ext}`;
    const key = `images/${filename}`;
    const existing = await env.ASSETS.head(key);
    if (!existing) {
      await env.ASSETS.put(key, bytes, {
        httpMetadata: { contentType: opts?.contentType ?? "application/octet-stream" },
        customMetadata: opts?.sourceUrl ? { source_url: opts.sourceUrl.slice(0, 1024) } : {},
      });
    }
    return publicAssetUrl(filename, canonicalAssetBase(env));
  } catch {
    return null;
  }
}

/** Reusable: fetch an arbitrary URL's bytes and mirror them into the ASSETS
 *  R2 bucket with sha256 dedup, returning the public
 *  https://api.brandnana.net/assets/<sha>.<ext> URL (or null on failure).
 *  This is the callable form of POST /mirror/images for a single URL — every
 *  binary (logo / screenshot / product image / ad creative / og:image)
 *  should flow through here so the book substrate is self-hosted, deduped,
 *  and survives upstream CDN rot. `ctx` lets callers waitUntil the R2 put
 *  without blocking the response. */
export async function mirrorToR2(
  env: Bindings,
  url: string,
  ctx?: ExecutionContext,
): Promise<string | null> {
  if (typeof url !== "string" || !url.startsWith("http")) return null;
  const got = await fetchBytes(url);
  if (!got) return null;
  // If a ctx is supplied, still await the put so we can return the final URL,
  // but let the caller keep the worker alive past the response if needed.
  void ctx;
  return storeBytesToR2(env, got.bytes, { contentType: got.contentType, sourceUrl: url });
}

// GET /assets/:filename — public asset proxy out of R2.
mirror.get("/assets/:filename", async (c) => {
  const filename = c.req.param("filename");
  if (!filename || filename.includes("/") || filename.includes("..")) {
    return c.json({ error: "invalid_filename" }, 400);
  }
  const key = `images/${filename}`;
  const obj = await c.env.ASSETS.get(key);
  if (!obj) return c.json({ error: "not_found" }, 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("cache-control", "public, max-age=31536000, immutable");
  headers.set("etag", obj.httpEtag);
  return new Response(obj.body, { headers });
});

interface MirrorBody {
  urls?: string[];
}

interface MirrorResult {
  mapping: Record<string, string>;
  skipped: string[];
  bytes_stored: number;
}

mirror.post("/mirror/images", requireBearer, async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as MirrorBody;
  if (!Array.isArray(body.urls) || body.urls.length === 0) {
    return c.json({ error: "missing_urls" }, 400);
  }
  if (body.urls.length > MAX_URLS_PER_CALL) {
    return c.json({ error: "too_many_urls", limit: MAX_URLS_PER_CALL }, 400);
  }

  // Asset URLs are pinned to the canonical base (api.brandnana.net /
  // MIRROR_ASSET_BASE) inside storeBytesToR2 — NEVER the request host. This
  // is the fault that leaked brandnana-api.shane-6d4.workers.dev into the
  // substrate when the CLI hit the worker via its *.workers.dev default host.
  const mapping: Record<string, string> = {};
  const skipped: string[] = [];
  let bytesStored = 0;

  // Dedup within this batch too — same URL twice = one fetch.
  const unique = [
    ...new Set(body.urls.filter((u) => typeof u === "string" && u.startsWith("http"))),
  ];

  await Promise.all(
    unique.map(async (url) => {
      try {
        const got = await fetchBytes(url);
        if (!got) {
          skipped.push(url);
          return;
        }
        const key = `images/${await sha256Hex(got.bytes)}.${extFromContentType(got.contentType, url)}`;
        const existing = await c.env.ASSETS.head(key);
        if (!existing) bytesStored += got.bytes.byteLength;
        const mirrored = await storeBytesToR2(c.env, got.bytes, {
          contentType: got.contentType,
          sourceUrl: url,
        });
        if (mirrored) mapping[url] = mirrored;
        else skipped.push(url);
      } catch {
        skipped.push(url);
      }
    }),
  );

  const result: MirrorResult = { mapping, skipped, bytes_stored: bytesStored };
  return c.json(result);
});

// POST /v1/asset/upload — store raw image BYTES (the request body) into R2 and
// return the public https://api.brandnana.net/assets/<sha>.<ext> URL.
//
// /mirror/images is the URL-based path (fetch a remote URL -> R2); this is the
// BYTES-based path for images the agent holds locally (a freshly generated PNG).
// It was 404 before, so the Designer fell back to flaky third-party temp hosts
// (tmpfiles) that serve HTML viewer pages OpenRouter can't read — the root
// enabler of the wb-5dti vision grind (wb-6x7p). Body = the raw image bytes,
// Content-Type = image/png|jpeg|webp|gif.
mirror.post("/v1/asset/upload", requireBearer, async (c) => {
  const contentType = (c.req.header("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("image/")) {
    return c.json({ error: "content_type_must_be_image", got: contentType }, 400);
  }
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength === 0) return c.json({ error: "empty_body" }, 400);
  const url = await storeBytesToR2(c.env, bytes, { contentType });
  if (!url) return c.json({ error: "store_failed_or_too_large" }, 413);
  return c.json({ ok: true, url });
});

export default mirror;
