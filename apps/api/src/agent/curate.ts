// agent.curate — Cerebras GLM-4.7 takes raw brand facts (logo, palette, real
// products, real ad lines) and returns slide-ready narrative + structure:
//
//   - cover_headline + cover_subhead    (a single launchable line)
//   - voice_notes                       (3-5 short bullets in the brand's own register)
//   - palette_roles                     (which color is primary/accent/etc; we keep the user's hex)
//   - slide_order                       (which slides to include + in what order)
//   - section_blurbs                    (one-line lede per slide)
//
// We DO NOT have the LLM invent hex codes, product names, prices, or fonts —
// those are already on the SeedBrand. The LLM's only job is the writing.
//
// If the Cerebras call errors, we fall back to deterministic defaults so the
// pipeline never blocks. Errors are surfaced via the returned warnings list.

import { chatJson, AiError } from "../ai.js";
import type { SeedBrand } from "./seed-brands.js";
import type { HomepageEvidence } from "./homepage-scrape.js";

export const ALL_SLIDES = [
  "cover",
  "identity",
  "homepage",
  "palette",
  "type",
  "voice",
  "catalog",
  "ads",
  "competitors",
  "social",
  "timeline",
] as const;

export type SlideKey = (typeof ALL_SLIDES)[number];

export interface CuratedBook {
  cover_headline: string;
  cover_subhead: string;
  voice_notes: string[];
  palette_roles: Array<{ hex: string; role: string; note: string }>;
  slide_order: SlideKey[];
  section_blurbs: Partial<Record<SlideKey, string>>;
  /** One-line auto-derived vibe (e.g. "Apothecary aesthetic, restrained
   *  typography, no photography"). Drives downstream agents' style cues. */
  style_signal: string;
  /** "cerebras" if the LLM responded, "fallback" if we used deterministic defaults. */
  source: "cerebras" | "fallback";
  /** Non-fatal issues (e.g. LLM rejected our shape; we used fallback for X). */
  warnings: string[];
  /** Cost + latency telemetry. */
  meta: {
    model: string;
    prompt_tokens: number;
    completion_tokens: number;
    latency_ms: number;
  };
}

interface CurationResponse {
  cover_headline?: string;
  cover_subhead?: string;
  voice_notes?: string[];
  palette_roles?: Array<{ hex?: string; role?: string; note?: string }>;
  slide_order?: string[];
  section_blurbs?: Record<string, string>;
  style_signal?: string;
}

function fallback(brand: SeedBrand, warnings: string[]): CuratedBook {
  return {
    cover_headline: brand.tagline || `${brand.brand_name} — brand book`,
    cover_subhead: `${brand.category}`,
    voice_notes: [
      `Brand: ${brand.brand_name}`,
      `Category: ${brand.category}`,
      `Tagline: ${brand.tagline}`,
    ],
    palette_roles: brand.palette.map((c, i) => ({
      hex: c.hex,
      role: i === 0 ? "primary" : i === 1 ? "secondary" : `accent ${i - 1}`,
      note: c.name,
    })),
    slide_order: [
      "cover",
      "identity",
      "palette",
      "type",
      "voice",
      "catalog",
      "ads",
      "competitors",
      "social",
      "timeline",
    ],
    section_blurbs: {
      identity: "How the brand presents itself.",
      homepage: "What the homepage looks like today.",
      palette: "Color system.",
      type: "Typographic system.",
      voice: "How the brand sounds.",
      catalog: "What the brand sells.",
      ads: "How the brand talks to its audience.",
      competitors: "Where the brand stands in the market.",
      social: "How the brand shows up online.",
      timeline: "How this book was captured.",
    },
    style_signal: brand.description.split(/[.!?]\s+/)[0]?.slice(0, 140) ?? brand.tagline,
    source: "fallback",
    warnings,
    meta: { model: "none", prompt_tokens: 0, completion_tokens: 0, latency_ms: 0 },
  };
}

const SYSTEM_PROMPT = `You are a brand strategist preparing a printed brand book. \
Given verified facts about a brand (name, category, palette, fonts, products, ad lines) \
AND optionally observed_evidence scraped LIVE from the brand's homepage \
(meta tags, CSS variables, dominant colors, font families used in CSS), \
write the NARRATIVE LAYER on top of those facts.

GROUNDING RULES — strict:
1. If observed_evidence is present, derive style_signal + voice_notes ONLY from it + the brand fields. \
   DO NOT invoke memory of the brand. If observed_evidence is sparse, your style_signal MUST reflect \
   that uncertainty (e.g. "Limited visual signal observed — primary color #cf0a2c, sans-serif body type").
2. You DO NOT invent products, prices, hex codes, fonts, logos, or URLs — those come from the input verbatim.
3. style_signal must be DEFENSIBLE against the evidence: don't claim "serif headlines" unless the observed \
   fonts include a serif face, don't claim "red accents" unless observed CSS includes red.

Reply with ONLY a JSON object. No prose, no markdown fences.

Schema:
{
  "cover_headline": "string, max 70 chars, in the brand's own register",
  "cover_subhead":  "string, max 90 chars, one-line context",
  "voice_notes":    ["3-5 short bullets, each <= 90 chars, describing how the brand SOUNDS"],
  "palette_roles":  [{ "hex": "echo input hex", "role": "primary|secondary|accent|background|surface|text|highlight", "note": "short why" }],
  "slide_order":    ["pick a sequence from: cover, identity, homepage, palette, type, voice, catalog, ads, competitors, social, timeline"],
  "section_blurbs": { "identity": "one-line lede", "homepage": "...", "palette": "...", "type": "...", "voice": "...", "catalog": "...", "ads": "...", "competitors": "...", "social": "...", "timeline": "..." },
  "style_signal":   "ONE line, max 140 chars, capturing the visual VIBE of this brand. Examples: 'Apothecary aesthetic, restrained type, almost no photography', 'Sun-drenched outdoor lifestyle with earthy palette', 'High-contrast hero typography over muted documentary photography'. Think art-director shorthand, not marketing copy."
}`;

function userPrompt(brand: SeedBrand, evidence?: HomepageEvidence): string {
  const payload: Record<string, unknown> = {
    brand: {
      name: brand.brand_name,
      domain: brand.domain,
      category: brand.category,
      tagline: brand.tagline,
      description: brand.description,
    },
    palette: brand.palette,
    fonts: { primary: brand.primary_font, secondary: brand.secondary_font },
    products_sample: brand.products.slice(0, 6).map((p) => ({
      name: p.name,
      price: p.price,
      currency: p.currency,
      category: p.category,
    })),
    ad_lines: brand.ads.map((a) => a.headline),
    competitor_names: brand.competitors.map((c) => c.name),
    social_networks: brand.social.map((s) => s.network),
  };
  if (evidence && !evidence.fetch_error) {
    payload.observed_evidence = {
      _note: "This is the LIVE homepage data we scraped from the site. Derive style_signal + voice_notes ONLY from these observations + the brand fields above. Do NOT invoke memory of the brand — if the evidence is sparse, say so in voice_notes rather than inventing.",
      meta: {
        title: evidence.meta.title,
        description: evidence.meta.description,
        og_title: evidence.meta.og_title,
        og_description: evidence.meta.og_description,
        theme_color: evidence.meta.theme_color,
      },
      brand_css_vars: evidence.brand_css_vars.slice(0, 30).map((v) => ({ name: v.name, value: v.value })),
      colors_ranked: evidence.colors_ranked.slice(0, 8),
      fonts: evidence.fonts.slice(0, 6),
    };
  }
  return JSON.stringify(payload);
}

function isSlideKey(s: string): s is SlideKey {
  return (ALL_SLIDES as readonly string[]).includes(s);
}

function clampStr(s: unknown, n: number): string {
  if (typeof s !== "string") return "";
  const t = s.trim();
  return t.length > n ? t.slice(0, n - 1) + "…" : t;
}

export async function curate(
  apiKey: string,
  brand: SeedBrand,
  opts: { evidence?: HomepageEvidence } = {},
): Promise<CuratedBook> {
  if (!apiKey) {
    return fallback(brand, ["CEREBRAS_API_KEY missing — used deterministic fallback"]);
  }

  const t0 = Date.now();
  try {
    const { value, usage, model } = await chatJson<CurationResponse>(apiKey, {
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userPrompt(brand, opts.evidence) },
      ],
      temperature: 0.4, // lower temperature when grounded in evidence — less invention
      max_tokens: 3000,
    });

    const fb = fallback(brand, []);

    // Slide order: respect Cerebras's preferred order but ENSURE every slide
    // is present (LLM can reorder, can't drop). Cover always first.
    const orderInput = Array.isArray(value.slide_order) ? value.slide_order : [];
    const dedup: SlideKey[] = [];
    for (const k of orderInput) {
      if (typeof k === "string" && isSlideKey(k) && !dedup.includes(k)) dedup.push(k);
    }
    // Append any slide the LLM forgot, in canonical order.
    for (const k of ALL_SLIDES) {
      if (!dedup.includes(k)) dedup.push(k);
    }
    // Canonical structural slot positions: cover first, identity + homepage
    // (high-impact visual context) right after, timeline last. Everything
    // else stays in the LLM's preferred order.
    function pin(key: SlideKey, position: number) {
      const i = dedup.indexOf(key);
      if (i < 0) return;
      dedup.splice(i, 1);
      dedup.splice(position, 0, key);
    }
    pin("cover", 0);
    pin("identity", 1);
    pin("homepage", 2);
    // timeline always last
    const ti = dedup.indexOf("timeline");
    if (ti >= 0 && ti !== dedup.length - 1) {
      dedup.splice(ti, 1);
      dedup.push("timeline");
    }
    const slide_order = dedup;

    // Palette roles: echo input hex set; only accept roles for hexes we know.
    const knownHex = new Set(brand.palette.map((c) => c.hex.toLowerCase()));
    const rolesIn = Array.isArray(value.palette_roles) ? value.palette_roles : [];
    const palette_roles = rolesIn
      .filter((r) => typeof r.hex === "string" && knownHex.has(r.hex.toLowerCase()))
      .map((r) => ({
        hex: r.hex as string,
        role: clampStr(r.role, 24) || "accent",
        note: clampStr(r.note, 60),
      }));
    // Fill in any missing hexes with defaults.
    const seenHex = new Set(palette_roles.map((r) => r.hex.toLowerCase()));
    for (let i = 0; i < brand.palette.length; i++) {
      const c = brand.palette[i];
      if (c && !seenHex.has(c.hex.toLowerCase())) {
        palette_roles.push({
          hex: c.hex,
          role: i === 0 ? "primary" : i === 1 ? "secondary" : `accent ${i - 1}`,
          note: c.name,
        });
      }
    }

    // Voice notes: cap to 5, clamp length.
    const voice_notes = (Array.isArray(value.voice_notes) ? value.voice_notes : [])
      .slice(0, 5)
      .map((s) => clampStr(s, 100))
      .filter((s) => s.length > 0);

    // Section blurbs: only known slide keys.
    const blurbsIn = (value.section_blurbs ?? {}) as Record<string, string>;
    const section_blurbs: Partial<Record<SlideKey, string>> = {};
    for (const [k, v] of Object.entries(blurbsIn)) {
      if (isSlideKey(k)) section_blurbs[k] = clampStr(v, 120);
    }

    return {
      cover_headline: clampStr(value.cover_headline, 80) || fb.cover_headline,
      cover_subhead: clampStr(value.cover_subhead, 100) || fb.cover_subhead,
      voice_notes: voice_notes.length > 0 ? voice_notes : fb.voice_notes,
      palette_roles,
      slide_order,
      section_blurbs: { ...fb.section_blurbs, ...section_blurbs },
      style_signal: clampStr(value.style_signal, 140) || fb.style_signal,
      source: "cerebras",
      warnings: [],
      meta: {
        model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        latency_ms: Date.now() - t0,
      },
    };
  } catch (err) {
    const msg =
      err instanceof AiError
        ? `Cerebras curate failed (${err.status}): ${err.message}`
        : `Cerebras curate threw: ${(err as Error).message}`;
    return fallback(brand, [msg]);
  }
}
