// POST /v1/book/publish — upload a PRE-COMPOSED deck .html so it is served at
// GET /books/<slug>.html.
//
// The ENGINE strategist composes its deck LOCALLY (a standalone .html bundle —
// see substrates/brandnana/profile/skills/compose-deck.org + publish-workbook.org)
// and needs a way to get that exact HTML in front of the public serve route so
// the VISUAL-REVIEW gate (POST /v1/book/render-slides) can fetch + screenshot it.
//
// This route writes the supplied html VERBATIM to the SAME R2 key that
// serve.ts reads for GET /books/<slug>.html:
//     brand-books/public/<slug>.html   (content-type text/html; charset=utf-8)
//
// It does NOT render anything server-side — the agent owns the composed HTML.
// (The cloud-side compose-and-render path is the separate POST /v1/book +
// /v1/book/seed/:slug pipeline.)
//
// Auth: existing bearer (same posture as the rest of /v1/book — mounted under a
// router that already applied requireBearer).
//
// Request body (application/json):
//   { slug: string, html: string }
//
// Response on success:
//   { ok: true, slug, url: "https://api.brandnana.net/books/<slug>.html", bytes }

import { Hono } from "hono";
import type { Bindings } from "../env.js";

const publish = new Hono<{ Bindings: Bindings }>();

// Canonical public host that serves /books/<slug>.html out of this same worker.
// Matches book/routes.ts + serve.ts + render-slides.ts — never derive from the
// request host (that leaks the *.workers.dev default host into URLs).
const PUBLIC_BASE = "https://api.brandnana.net";

// 8 MiB — a composed standalone deck (HTML + inlined CSS + a base64
// wb-source-bundle) is comfortably under this; reject anything pathological.
const MAX_HTML_BYTES = 8 * 1024 * 1024;

// ── wb-source-bundle validation (wb-8snp / wb-ann4 robustness) ─────────────────
//
// The agent composes the deck LOCALLY and we serve its HTML VERBATIM — so a
// hand-rolled/malformed bundle (e.g. raw .org mislabeled json+gzip+base64) used
// to ship undetected (wb-ann4). We can't REBUILD the bundle server-side (that
// needs the .org source publish doesn't have), so we VALIDATE-AND-REJECT: the
// embedded bundle must round-trip exactly as `wb unbundle` would decode it.
//
// This mirrors the forge contract (cli/wb/.../bundle/embedSource.mjs +
// commands/unbundle.mjs): locate the block, base64→gunzip→JSON.parse, assert
// manifest.files is an array. gunzip uses DecompressionStream (Workers-native),
// the inverse of book-bundle.ts's CompressionStream.

const BUNDLE_MARKER_OPEN = '<script id="wb-source-bundle"';
const BUNDLE_MARKER_CLOSE = "</script>";

type BundleCheck =
  | { ok: true; fileCount: number }
  | { ok: false; reason: string };

/** Decode standard base64 to bytes. Workers-compatible (inverse of book-bundle.ts). */
function base64ToUint8(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Gunzip via DecompressionStream — the inverse of book-bundle.ts's gzip. */
async function gunzip(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Response(
    new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip")),
  );
  return new Uint8Array(await stream.arrayBuffer());
}

/**
 * Validate that the incoming HTML carries a wb-source-bundle that round-trips
 * exactly the way `wb unbundle` decodes it: base64 → gunzip → JSON.parse →
 * `manifest.files` is an array. Returns a typed result rather than throwing.
 */
export async function validateSourceBundle(html: string): Promise<BundleCheck> {
  const start = html.indexOf(BUNDLE_MARKER_OPEN);
  if (start < 0) {
    return { ok: false, reason: "no <script id=\"wb-source-bundle\"> block found" };
  }
  const tagEnd = html.indexOf(">", start);
  if (tagEnd < 0) return { ok: false, reason: "wb-source-bundle script tag is unterminated" };
  const close = html.indexOf(BUNDLE_MARKER_CLOSE, tagEnd);
  if (close < 0) return { ok: false, reason: "wb-source-bundle script tag is unclosed" };

  const b64 = html.slice(tagEnd + 1, close).trim();
  if (!b64) return { ok: false, reason: "wb-source-bundle is empty" };

  let manifest: unknown;
  try {
    const gz = base64ToUint8(b64);
    const json = new TextDecoder().decode(await gunzip(gz));
    manifest = JSON.parse(json);
  } catch (e) {
    return { ok: false, reason: `bundle did not decode (base64→gunzip→JSON): ${(e as Error).message}` };
  }

  if (typeof manifest !== "object" || manifest === null) {
    return { ok: false, reason: "decoded manifest is not an object" };
  }
  const files = (manifest as { files?: unknown }).files;
  if (!Array.isArray(files)) {
    return { ok: false, reason: "manifest.files is missing or not an array" };
  }
  return { ok: true, fileCount: files.length };
}

/** Sanitize a requested slug to the [a-z0-9-] charset serve.ts will accept.
 *  Returns null if nothing usable remains. */
function sanitizeSlug(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const slug = raw
    .toLowerCase()
    .trim()
    .replace(/\.html$/i, "") // tolerate a trailing .html
    .replace(/[^a-z0-9-]+/g, "-") // collapse anything else to a single dash
    .replace(/^-+|-+$/g, ""); // trim leading/trailing dashes
  if (!slug) return null;
  // Cap length so the R2 key stays sane.
  return slug.slice(0, 120);
}

publish.post("/", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    slug?: string;
    html?: string;
  };

  const slug = sanitizeSlug(body.slug);
  if (!slug) {
    return c.json(
      { error: "invalid_slug", message: "slug is required and must contain [a-z0-9-] characters" },
      400,
    );
  }

  if (typeof body.html !== "string" || body.html.length === 0) {
    return c.json(
      { error: "missing_html", message: "html is required (the composed deck as a string)" },
      400,
    );
  }

  const bytes = new TextEncoder().encode(body.html);
  if (bytes.byteLength > MAX_HTML_BYTES) {
    return c.json(
      {
        error: "html_too_large",
        message: `html exceeds ${MAX_HTML_BYTES} bytes`,
        limit: MAX_HTML_BYTES,
        bytes: bytes.byteLength,
      },
      413,
    );
  }

  // Reject any deck whose wb-source-bundle is missing or doesn't round-trip —
  // a hand-rolled/malformed bundle must never reach the public serve route
  // (wb-8snp / wb-ann4). We validate-and-reject rather than rebuild because
  // publish has no .org source to rebuild from.
  const bundle = await validateSourceBundle(body.html);
  if (!bundle.ok) {
    return c.json(
      {
        error: "invalid_source_bundle",
        message: `malformed/missing wb-source-bundle — rebuild with wb embed-source (${bundle.reason})`,
        detail: bundle.reason,
      },
      422,
    );
  }

  // Write to the EXACT key serve.ts reads for GET /books/<slug>.html.
  const key = `brand-books/public/${slug}.html`;
  const user = c.get("user");
  try {
    await c.env.ASSETS.put(key, bytes, {
      httpMetadata: { contentType: "text/html; charset=utf-8" },
      customMetadata: {
        slug,
        visibility: "public",
        kind: "agent_composed",
        account_id: user.id,
        published_at: new Date().toISOString(),
      },
    });
  } catch (e) {
    return c.json({ error: "r2_write_failed", message: (e as Error).message }, 502);
  }

  return c.json({
    ok: true,
    slug,
    url: `${PUBLIC_BASE}/books/${slug}.html`,
    bytes: bytes.byteLength,
  });
});

export default publish;
