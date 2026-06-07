// Server-side creative vision — analyze ONE ad creative into a structured
// schema, performed INSIDE the worker so the OpenRouter key never leaves the
// server. This is the worker-side mirror of apps/cli/src/commands/creative-vision.ts:
// the routing (image / carousel-aware single-image / video with a poster-frame
// fallback) and the minimax/minimax-m3 model choice are kept in lockstep so the
// CLI's printed `analysis` shape is identical whether produced locally (--local)
// or server-side (the agent's default path).
//
// Differences from the CLI module:
//   - The OpenRouter key is passed in by the route from env.OPENROUTER_API_KEY
//     (the worker binding) — it is NEVER read from process.env or the request.
//   - Runs under Cloudflare nodejs_compat, so Buffer/base64 for the inline-video
//     path works exactly as it does in the CLI.
//   - Single-creative only (the route is one-URL-per-call); batch pooling stays
//     in the CLI for piping `ads search | creative analyze`.

import { imagePart } from "../llm/image-input.js";

const MINIMAX = "minimax/minimax-m3";
const OPENROUTER = "https://openrouter.ai/api/v1/chat/completions";

// Wall-clock ceilings so a slow/stuck upstream can NEVER stall a run. A real
// vision call returns in seconds; 90s is generous headroom. Media fetches are
// short ad assets, so 30s is ample. On timeout the fetch rejects with an
// AbortError that the surrounding try/catch turns into the SAME normalize(null,
// …, error) / posterFallback path as any other failure — no creative is dropped.
const VISION_TIMEOUT_MS = 90_000;
const MEDIA_FETCH_TIMEOUT_MS = 30_000;

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
  url: string;
  poster_url?: string | null;
  /** optional: the ad's body/cta text, given to the model as context. */
  context?: string;
}

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
    // Inline each image as a base64 data URI so OpenRouter never has to fetch
    // the URL itself (the failure mode for rendered/temp-hosted slides).
    const imageParts = await Promise.all(urls.map((url) => imagePart(url, fetchImpl)));
    const res = await fetchImpl(OPENROUTER, {
      method: "POST",
      signal: AbortSignal.timeout(VISION_TIMEOUT_MS),
      headers: {
        Authorization: `Bearer ${openrouterKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/shinyobjectz/brandnana",
        "X-Title": "brandnana",
      },
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
    let parsed = parseJsonLoose<Partial<CreativeAnalysis>>(raw);
    // minimax replies in PROSE (not JSON) on ~30% of slide renders (run #8: 14/45;
    // wb-syjo). parseJsonLoose then drops EVERYTHING and the verdict normalizes to
    // all-empty even though the model SAW and described the slide. Keep the prose as
    // `summary` so the description survives the review — flag it via `error` so it
    // reads as prose, not clean JSON. Self-diagnosing error (wb-ljze): the raw
    // response makes a vision failure one glance ("I can't see images" = model;
    // "<html>" = bad URL; near-JSON = format) instead of a blind retry loop.
    const prose = !parsed && raw.trim().length > 0;
    if (prose) parsed = { summary: raw.trim().slice(0, 1000) };
    const err = prose
      ? `prose (not JSON): ${raw.slice(0, 160)}`
      : parsed
        ? undefined
        : `unparseable: ${raw.slice(0, 200)}`;
    return normalize(parsed, format, "minimax", err);
  } catch (e) {
    return normalize(null, format, "minimax", (e as Error).message);
  }
}

// ── Video → minimax-m3 (OpenRouter), poster-frame fallback on ANY failure ────
//
// Routes VIDEO through the SAME OpenRouter minimax-m3 endpoint as images. We
// inline the video bytes as a base64 data-uri and send them as a multimodal
// content part. On ANY failure (non-2xx, unparseable, thrown error, or the
// model simply not supporting inline video) we fall back to analyzing the
// POSTER FRAME as a minimax image — so a video ALWAYS yields an analysis.
//
// !!! VIDEO STILL NEEDS A LIVE TEST !!! The direct-video part shape mirrors
// image_url; only a real call confirms OpenRouter passes inline video through
// to minimax-m3 (vs. silently dropping it / erroring into the poster fallback).

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
  openrouterKey: string,
  fetchImpl: typeof fetch,
): Promise<CreativeAnalysis> {
  // Inline the video bytes (ads are short; fine as an inline data-uri).
  let buf: Buffer;
  let mime: string;
  try {
    const vr = await fetchImpl(c.url, {
      signal: AbortSignal.timeout(MEDIA_FETCH_TIMEOUT_MS),
      headers: { "User-Agent": "brandnana-creative/1.0" },
    });
    if (!vr.ok) return posterFallback(c, openrouterKey, fetchImpl, `, fetch ${vr.status}`);
    buf = Buffer.from(await vr.arrayBuffer());
    if (buf.length > 18_000_000) {
      // Too large to inline; fall back to the poster frame.
      return posterFallback(c, openrouterKey, fetchImpl, ", video too large to inline");
    }
    mime = vr.headers.get("content-type") || "video/mp4";
  } catch (e) {
    return posterFallback(c, openrouterKey, fetchImpl, `, ${(e as Error).message}`);
  }

  const dataUri = `data:${mime};base64,${buf.toString("base64")}`;
  const ctx = c.context ? ` Ad copy for context: ${JSON.stringify(c.context).slice(0, 400)}.` : "";
  try {
    const res = await fetchImpl(OPENROUTER, {
      method: "POST",
      signal: AbortSignal.timeout(VISION_TIMEOUT_MS),
      headers: {
        Authorization: `Bearer ${openrouterKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/shinyobjectz/brandnana",
        "X-Title": "brandnana",
      },
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
              { type: "video_url", video_url: { url: dataUri } },
            ],
          },
        ],
      }),
    });
    if (!res.ok) return posterFallback(c, openrouterKey, fetchImpl, `, minimax ${res.status}`);
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const parsed = parseJsonLoose<Partial<CreativeAnalysis>>(
      data.choices?.[0]?.message?.content ?? "",
    );
    if (!parsed) return posterFallback(c, openrouterKey, fetchImpl, ", unparseable");
    return normalize(parsed, "video", "minimax", undefined);
  } catch (e) {
    return posterFallback(c, openrouterKey, fetchImpl, `, ${(e as Error).message}`);
  }
}

// ── Public: analyze one creative ─────────────────────────────────────────────

export async function analyzeCreative(
  c: Creative,
  keys: { openrouter: string },
  fetchImpl: typeof fetch = fetch,
): Promise<CreativeAnalysis> {
  if (c.kind === "video") return analyzeVideo(c, keys.openrouter, fetchImpl);
  return analyzeImages([c.url], keys.openrouter, c.context, fetchImpl);
}
