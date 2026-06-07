// Creative vision — analyze ad creatives (from `ads search` / ScrapeCreators)
// into a structured schema so the agent (and workflows) can reason over what an
// ad actually SHOWS, not just its text. Routed by media kind, pooled for scale.
//
// NOTE ON DEPLOYMENT: this module calls OpenRouter DIRECTLY using a key passed in
// by the caller. It now backs ONLY the `--local` path of `creative analyze`
// (operator/CI use) plus batch pooling — the default agent path goes CLI→server
// (apps/api/src/creative/routes.ts) because the engine scrubs "*_API_KEY" from
// the agent's bash. The worker keeps its own copy of this routing logic
// (apps/api/src/creative/vision.ts); the two MUST stay in lockstep so the
// printed `analysis` shape is identical whether produced locally or server-side.
//
// Everything routes through OpenRouter minimax-m3 (text-out, vision-input:
// image+video) — one provider, one key (OPENROUTER_API_KEY), no Gemini:
//
//   image     → minimax-m3 via OpenRouter (image_url content part).
//   carousel  → minimax-m3, ALL slides in ONE call (analyzed as a single
//               creative, then noted per-slide), so it reads the carousel as
//               one idea.
//   video     → minimax-m3 via OpenRouter as an inline data-uri video part
//               (best-effort — see analyzeVideo; NEEDS A LIVE TEST). On ANY
//               failure (non-2xx, unparseable, or no video support) it falls
//               back to analyzing the poster frame as a minimax image, so a
//               video ALWAYS yields an analysis.
//
// Parallelized with a bounded work pool: 100 ads don't wait on each other.

export interface CreativeAnalysis {
  format: "image" | "carousel" | "video";
  /** The attention-grab — the first thing a viewer registers. */
  hook: string;
  /** What the creative centres on. Product-first matters for ad strategy. */
  subject_focus: "product" | "person" | "both" | "scene" | "text" | "unknown";
  products_visible: string[];
  people_count: number;
  setting: string;
  /** On-creative copy (overlays, captions). */
  text_overlays: string[];
  cta_visible: boolean;
  mood: string;
  palette: string[];
  /** video only */
  pacing?: "fast" | "medium" | "slow";
  /** video only — beats/scenes in order */
  key_moments?: string[];
  summary: string;
  /** model used, e.g. "minimax" | "minimax(poster)". */
  via: string;
  /** populated when analysis failed (creative still returned, never dropped). */
  error?: string;
}

export interface Creative {
  kind: "image" | "video";
  /** image: one URL. carousel: caller passes kind:image once per slide with the
   *  same group — see analyzeAd. video: the video URL. */
  url: string;
  poster_url?: string | null;
  /** optional: the ad's body/cta text, given to the model as context. */
  context?: string;
}

const MINIMAX = "minimax/minimax-m3";
const OPENROUTER = "https://openrouter.ai/api/v1/chat/completions";

const IMAGE_SCHEMA =
  '{"hook":"","subject_focus":"product|person|both|scene|text",' +
  '"products_visible":[],"people_count":0,"setting":"","text_overlays":[],' +
  '"cta_visible":false,"mood":"","palette":["#hex"],"summary":""}';

const VIDEO_SCHEMA =
  '{"hook":"","subject_focus":"product|person|both|scene|text",' +
  '"products_visible":[],"people_count":0,"setting":"","text_overlays":[],' +
  '"cta_visible":false,"mood":"","palette":["#hex"],"pacing":"fast|medium|slow",' +
  '"key_moments":[],"summary":""}';

function parseJsonLoose<T>(text: string): T | null {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return null;
  try {
    return JSON.parse(m[0]) as T;
  } catch {
    return null;
  }
}

function normalize(
  parsed: Partial<CreativeAnalysis> | null,
  format: CreativeAnalysis["format"],
  via: string,
  error?: string,
): CreativeAnalysis {
  const p = parsed ?? {};
  return {
    format,
    hook: p.hook ?? "",
    subject_focus: p.subject_focus ?? "unknown",
    products_visible: Array.isArray(p.products_visible) ? p.products_visible : [],
    people_count: typeof p.people_count === "number" ? p.people_count : 0,
    setting: p.setting ?? "",
    text_overlays: Array.isArray(p.text_overlays) ? p.text_overlays : [],
    cta_visible: !!p.cta_visible,
    mood: p.mood ?? "",
    palette: Array.isArray(p.palette) ? p.palette.slice(0, 6) : [],
    ...(p.pacing ? { pacing: p.pacing } : {}),
    ...(Array.isArray(p.key_moments) ? { key_moments: p.key_moments } : {}),
    summary: p.summary ?? "",
    via,
    ...(error ? { error } : {}),
  };
}

// ── Images / carousels → minimax-m3 (OpenRouter) ─────────────────────────────

// Inline the image bytes as a data URI so OpenRouter never has to fetch the URL
// itself (its backend can't reach rendered/temp-hosted slides — wb-5dti). Kept
// in LOCKSTEP with apps/api/src/llm/image-input.ts (separate package, so copied,
// not imported). Falls back to the plain URL if the fetch isn't a usable image.
const MAX_INLINE_BYTES = 8 * 1024 * 1024;

function inlineMime(ct: string | null | undefined): string {
  const sub = (ct ?? "").split("/")[1]?.split(";")[0]?.trim().toLowerCase();
  if (sub === "jpg" || sub === "jpeg") return "image/jpeg";
  if (sub === "png" || sub === "webp" || sub === "gif") return `image/${sub}`;
  return "image/png";
}

async function imagePart(
  url: string,
  fetchImpl: typeof fetch,
): Promise<{ type: "image_url"; image_url: { url: string } }> {
  let inlined: string | null = null;
  if (url.startsWith("data:")) {
    inlined = url;
  } else {
    try {
      const r = await fetchImpl(url, {
        redirect: "follow",
        headers: { accept: "image/avif,image/webp,image/png,image/*,*/*;q=0.8" },
      });
      const ct = r.headers.get("content-type");
      // content-type guard: temp hosts serve an HTML viewer page — don't wrap it.
      if (r.ok && (!ct || ct.toLowerCase().startsWith("image/"))) {
        const buf = await r.arrayBuffer();
        if (buf.byteLength > 0 && buf.byteLength <= MAX_INLINE_BYTES) {
          inlined = `data:${inlineMime(ct)};base64,${Buffer.from(buf).toString("base64")}`;
        }
      }
    } catch {
      /* fall back to the plain URL */
    }
  }
  return { type: "image_url", image_url: { url: inlined ?? url } };
}

async function analyzeImages(
  urls: string[],
  openrouterKey: string,
  context: string | undefined,
  fetchImpl: typeof fetch,
): Promise<CreativeAnalysis> {
  const format = urls.length > 1 ? "carousel" : "image";
  const lead =
    format === "carousel"
      ? `This is a ${urls.length}-slide ad CAROUSEL — read all slides as ONE creative (a single idea told across slides).`
      : "This is a single-image ad creative.";
  const ctx = context ? ` Ad copy for context: ${JSON.stringify(context).slice(0, 400)}.` : "";
  try {
    // Inline images as data URIs (lockstep with apps/api image-input.ts, wb-5dti).
    const imageParts = await Promise.all(urls.map((url) => imagePart(url, fetchImpl)));
    const res = await fetchImpl(OPENROUTER, {
      method: "POST",
      headers: { Authorization: `Bearer ${openrouterKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: MINIMAX,
        temperature: 0,
        max_tokens: 500,
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: `${lead}${ctx} Reply with ONLY this JSON: ${IMAGE_SCHEMA}` },
              ...imageParts,
            ],
          },
        ],
      }),
    });
    if (!res.ok) return normalize(null, format, "minimax", `http ${res.status}`);
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const raw = data.choices?.[0]?.message?.content ?? "";
    const parsed = parseJsonLoose<Partial<CreativeAnalysis>>(raw);
    // Self-diagnosing error (wb-ljze, lockstep with apps/api/creative/vision.ts).
    return normalize(parsed, format, "minimax", parsed ? undefined : `unparseable: ${raw.slice(0, 200)}`);
  } catch (e) {
    return normalize(null, format, "minimax", (e as Error).message);
  }
}

// ── Video → minimax-m3 (OpenRouter), poster-frame fallback on ANY failure ────
//
// Routes VIDEO through the SAME OpenRouter minimax-m3 endpoint as images. We
// inline the video bytes as a base64 data-uri and send them as a multimodal
// content part. OpenRouter's exact inline-video content-part shape is NOT yet
// confirmed for minimax — we send a best-effort `{type:"video_url",
// video_url:{url:<data-uri>}}` part (mirrors the image_url shape, which is what
// OpenRouter documents for media parts). On ANY failure (non-2xx, unparseable,
// thrown error, or the model simply not supporting inline video) we fall back
// to analyzing the POSTER FRAME as a minimax image — which definitely works —
// so a video ALWAYS yields an analysis. No Gemini key needed.
//
// !!! VIDEO NEEDS A LIVE TEST !!! The direct-video path above is best-effort;
// only a real call against the deployed CLI can confirm OpenRouter actually
// passes inline video through to minimax-m3 (vs. silently dropping it / erroring
// into the poster fallback). See the report's "VIDEO NEEDS LIVE TEST" note.

async function posterFallback(
  c: Creative,
  openrouterKey: string,
  fetchImpl: typeof fetch,
  viaSuffix: string,
): Promise<CreativeAnalysis> {
  if (c.poster_url) {
    const a = await analyzeImages([c.poster_url], openrouterKey, c.context, fetchImpl);
    return { ...a, format: "video", via: `minimax(poster${viaSuffix})` };
  }
  return normalize(
    null,
    "video",
    "minimax",
    `video direct path failed (${viaSuffix.replace(/^, /, "")}); no poster_url to fall back to`,
  );
}

async function analyzeVideo(
  c: Creative,
  keys: { openrouter: string; gemini?: string },
  fetchImpl: typeof fetch,
): Promise<CreativeAnalysis> {
  // Inline the video bytes (ads are short; fine as an inline data-uri).
  let buf: Buffer;
  let mime: string;
  try {
    const vr = await fetchImpl(c.url, { headers: { "User-Agent": "brandnana-creative/1.0" } });
    if (!vr.ok) return posterFallback(c, keys.openrouter, fetchImpl, `, fetch ${vr.status}`);
    buf = Buffer.from(await vr.arrayBuffer());
    if (buf.length > 18_000_000) {
      // Too large to inline; fall back to the poster frame.
      return posterFallback(c, keys.openrouter, fetchImpl, ", video too large to inline");
    }
    mime = vr.headers.get("content-type") || "video/mp4";
  } catch (e) {
    return posterFallback(c, keys.openrouter, fetchImpl, `, ${(e as Error).message}`);
  }

  // Best-effort direct video → minimax-m3 via OpenRouter as an inline data-uri.
  const dataUri = `data:${mime};base64,${buf.toString("base64")}`;
  const ctx = c.context ? ` Ad copy for context: ${JSON.stringify(c.context).slice(0, 400)}.` : "";
  try {
    const res = await fetchImpl(OPENROUTER, {
      method: "POST",
      headers: { Authorization: `Bearer ${keys.openrouter}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: MINIMAX,
        temperature: 0,
        max_tokens: 500,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "text",
                text: `Analyze this ad VIDEO.${ctx} Reply with ONLY this JSON: ${VIDEO_SCHEMA}`,
              },
              // Best-effort inline-video part. OpenRouter's confirmed media part
              // is `image_url`; the `video_url` shape mirrors it for video. If
              // minimax can't read it, the catch / non-2xx below routes us to the
              // poster fallback, so this never hard-fails. NEEDS A LIVE TEST.
              { type: "video_url", video_url: { url: dataUri } },
            ],
          },
        ],
      }),
    });
    if (!res.ok) return posterFallback(c, keys.openrouter, fetchImpl, `, minimax ${res.status}`);
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const parsed = parseJsonLoose<Partial<CreativeAnalysis>>(
      data.choices?.[0]?.message?.content ?? "",
    );
    if (!parsed) return posterFallback(c, keys.openrouter, fetchImpl, ", unparseable");
    return normalize(parsed, "video", "minimax", undefined);
  } catch (e) {
    return posterFallback(c, keys.openrouter, fetchImpl, `, ${(e as Error).message}`);
  }
}

// ── Public: analyze one creative ─────────────────────────────────────────────

export async function analyzeCreative(
  c: Creative,
  keys: { openrouter: string; gemini?: string },
  fetchImpl: typeof fetch = fetch,
): Promise<CreativeAnalysis> {
  if (c.kind === "video") return analyzeVideo(c, keys, fetchImpl);
  return analyzeImages([c.url], keys.openrouter, c.context, fetchImpl);
}

// An ad may carry multiple image slides (a carousel) — analyze them as one.
export async function analyzeAd(
  ad: { kind: "image" | "video"; urls: string[]; poster_url?: string | null; context?: string },
  keys: { openrouter: string; gemini?: string },
  fetchImpl: typeof fetch = fetch,
): Promise<CreativeAnalysis> {
  if (ad.kind === "video") {
    return analyzeVideo(
      { kind: "video", url: ad.urls[0] ?? "", poster_url: ad.poster_url, context: ad.context },
      keys,
      fetchImpl,
    );
  }
  return analyzeImages(ad.urls, keys.openrouter, ad.context, fetchImpl);
}

// ── Bounded work pool — analyze many without serial waiting ──────────────────

export async function pool<T, R>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let cursor = 0;
  const n = Math.max(1, Math.min(concurrency, items.length));
  await Promise.all(
    Array.from({ length: n }, async () => {
      while (true) {
        const i = cursor++;
        if (i >= items.length) return;
        results[i] = await worker(items[i] as T, i);
      }
    }),
  );
  return results;
}
