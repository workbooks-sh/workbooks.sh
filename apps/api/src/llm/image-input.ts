// Shared OpenRouter image-input builder.
//
// THE FAULT THIS FIXES: every brandnana vision path used to hand OpenRouter a
// raw `image_url: { url: someHttpUrl }` and rely on OpenRouter's BACKEND to
// fetch that URL. That works for already-public, CDN-reachable images, but
// fails silently for anything OpenRouter can't fetch (freshly-rendered slides
// mirrored to a host its fetcher can't reach, short-TTL temp-file redirects,
// auth/region-gated URLs). When the fetch yields nothing the model "sees"
// nothing, returns non-JSON, and the caller labels it "unparseable" — the exact
// failure that ground the Designer for 129 turns on a rendered deck (wb-5dti).
//
// Per OpenRouter's docs the correct path for non-public / rendered-in-memory
// images is an INLINE base64 data URI in image_url.url. So we fetch the bytes
// OURSELVES (the worker can reach api.brandnana.net R2, mshots, temp hosts that
// OpenRouter's fetcher can't) and inline them. If our own fetch fails we fall
// back to the plain-URL part — preserving the already-working public-image case
// rather than regressing it.
//
// This is the ONE place that builds an image content part. All four vision
// paths (creative/vision.ts, design/palette.ts, book/harvest.ts,
// agent/vision-verify.ts) import imagePart() so the shape can never drift.

import { browserHeaders } from "../scrape/headers.js";

/** OpenRouter/OpenAI Chat-Completions image content part (object form). */
export interface ImagePart {
  type: "image_url";
  image_url: { url: string };
}

/** OpenRouter accepts only these for inline data URIs; default to png. */
function inlineMime(contentType: string | null | undefined): string {
  const sub = (contentType ?? "").split("/")[1]?.split(";")[0]?.trim().toLowerCase();
  if (sub === "jpg" || sub === "jpeg") return "image/jpeg";
  if (sub === "png" || sub === "webp" || sub === "gif") return `image/${sub}`;
  return "image/png";
}

const MAX_INLINE_BYTES = 8 * 1024 * 1024; // 8 MiB raw; ~10.6 MiB base64
const FETCH_TIMEOUT_MS = 15_000;

/**
 * Build an OpenRouter image content part for `url`, preferring an INLINE base64
 * data URI (so OpenRouter never has to fetch the URL itself). Falls back to the
 * plain-URL part if our server-side fetch fails or the image is too large to
 * inline — i.e. the previous behavior, used only when inlining isn't possible.
 */
export async function imagePart(url: string, fetchImpl: typeof fetch = fetch): Promise<ImagePart> {
  const dataUri = await toDataUri(url, fetchImpl);
  return { type: "image_url", image_url: { url: dataUri ?? url } };
}

/**
 * Fetch `url` server-side and return a `data:<mime>;base64,<...>` URI, or null
 * if the fetch fails / the image is empty / it exceeds the inline byte cap.
 */
export async function toDataUri(url: string, fetchImpl: typeof fetch = fetch): Promise<string | null> {
  // A url that's already a data URI is inline-ready — don't double-wrap.
  if (url.startsWith("data:")) return url;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetchImpl(url, {
      signal: ctrl.signal,
      redirect: "follow",
      headers: browserHeaders({ accept: "image/avif,image/webp,image/png,image/*,*/*;q=0.8" }),
    });
    if (!r.ok) return null;
    // Content-type guard (wb-5dti verify): temp-file hosts (e.g. tmpfiles.org)
    // return an HTML *viewer* page (text/html, 200, nonzero) for a share URL.
    // Without this we'd wrap that HTML as a fake data:image/png and OpenRouter
    // still sees garbage -> "unparseable". Reject non-image bodies so the caller
    // fails cleanly instead of silently shipping HTML as an image.
    const ct = r.headers.get("content-type");
    if (ct && !ct.toLowerCase().startsWith("image/")) return null;
    const buf = await r.arrayBuffer();
    if (buf.byteLength === 0 || buf.byteLength > MAX_INLINE_BYTES) return null;
    const mime = inlineMime(ct);
    return `data:${mime};base64,${Buffer.from(buf).toString("base64")}`;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}
