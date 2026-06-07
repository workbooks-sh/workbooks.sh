// Shared brand-palette union.
//
// THE PALETTE FAULT: the design.tokens / brand.fetch verbs derived the palette
// ONLY from context.dev's vendor `brand.colors`. For tecovas context.dev
// returns exactly 3 colors, so the gathered tokens.json carried 3 hexes and
// the deterministic substrate builder faithfully rendered 3 — below the >=6
// gate. The rich always-union (vendor colors + homepage theme-color + brand
// CSS vars + dominant ranked colors + a vision-on-screenshot fallback) lived
// ONLY in the in-process book pipeline (book/harvest.ts harvestIdentity),
// which the flash-harvest gather verbs never call.
//
// This module ports that union so the verbs the gather DOES call (GET
// /design/tokens/:domain and GET /brand/:domain) can return >=6 role-tagged
// swatches deterministically — no agent-discretion `creative analyze` step.
//
// Inputs are unioned in priority order and deduped by normalized hex:
//   1. context.dev vendor colors      (role primary/secondary/accent by index)
//   2. homepage <meta theme-color>
//   3. homepage brand CSS custom props (--color-*, --primary, …)
//   4. homepage dominant colors ranked by occurrence
//   5. vision-on-screenshot fallback   (only fired if still < TARGET swatches)

import type { ContextBrandColor } from "../scrape/context.js";
import type { HomepageEvidence } from "../agent/homepage-scrape.js";
import { imagePart } from "../llm/image-input.js";

const OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const VISION_MODEL = "minimax/minimax-m3";

/** Minimum swatch count the >=6 substrate gate requires. We union until we
 *  reach this; the vision fallback only fires while still short. */
export const PALETTE_TARGET = 6;
/** Hard cap so a pathological CSS file can't balloon the palette. */
const PALETTE_MAX = 12;

export interface Swatch {
  hex: string;
  name: string;
  /** primary | secondary | accent | neutral | undefined (supporting). */
  role?: string;
}

export interface UnionPaletteResult {
  swatches: Swatch[];
  /** Flat hex list for legacy `palette.all: string[]` consumers. */
  hexes: string[];
  /** Tagged source counts for provenance / debugging. */
  sources: {
    vendor: number;
    theme_color: number;
    css_vars: number;
    ranked: number;
    vision: number;
  };
}

/** Normalize to #rrggbb (drops shorthand/alpha) or null if not a hex. */
export function normalizeHex(raw: string | undefined | null): string | null {
  if (!raw) return null;
  const v = raw.trim().toLowerCase();
  if (/^#[0-9a-f]{6}$/.test(v)) return v;
  if (/^#[0-9a-f]{3}$/.test(v)) return "#" + v.slice(1).split("").map((c) => c + c).join("");
  if (/^#[0-9a-f]{8}$/.test(v)) return v.slice(0, 7); // drop alpha
  return null;
}

function isNeutral(hex: string): boolean {
  const h = hex.replace("#", "");
  if (h.length !== 6) return false;
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return Math.max(r, g, b) - Math.min(r, g, b) < 16;
}

/** Vision-on-screenshot color extractor (same model/shape as harvest.ts). */
async function visionColors(
  apiKey: string | undefined,
  screenshotUrl: string,
  brandName: string,
): Promise<string[]> {
  if (!apiKey || !screenshotUrl) return [];
  try {
    const r = await fetch(OPENROUTER_ENDPOINT, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
        "http-referer": "https://brandnana.net",
        "x-title": "brandnana",
      },
      body: JSON.stringify({
        model: VISION_MODEL,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "text",
                text: `Look at this brand homepage screenshot for "${brandName}". Return JSON {"colors":["#hex", ...]} listing the 6-10 most prominent brand colors as hex.`,
              },
              await imagePart(screenshotUrl),
            ],
          },
        ],
        temperature: 0.2,
        max_tokens: 800,
        response_format: { type: "json_object" },
      }),
    });
    if (!r.ok) return [];
    const data = (await r.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const raw = data.choices?.[0]?.message?.content ?? "";
    const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
    const parsed = JSON.parse(cleaned) as { colors?: string[] };
    return parsed.colors ?? [];
  } catch {
    return [];
  }
}

/**
 * Build the unioned brand palette. `evidence` and `screenshotUrl` are optional
 * so callers that only have vendor colors still get a (thin) palette; supplying
 * homepage evidence + a screenshot URL + an OpenRouter key is what lifts the
 * count to >=6. The vision pass only fires when the union is still short, so a
 * brand with a rich CSS palette never pays for an LLM call.
 */
export async function unionBrandPalette(args: {
  vendorColors?: ContextBrandColor[];
  evidence?: HomepageEvidence | null;
  screenshotUrl?: string | null;
  brandName?: string;
  openrouterApiKey?: string;
}): Promise<UnionPaletteResult> {
  const swatches: Swatch[] = [];
  const seen = new Set<string>();
  const sources = { vendor: 0, theme_color: 0, css_vars: 0, ranked: 0, vision: 0 };

  const add = (raw: string | undefined, name: string, role?: string): boolean => {
    const hex = normalizeHex(raw);
    if (!hex || seen.has(hex)) return false;
    if (swatches.length >= PALETTE_MAX) return false;
    seen.add(hex);
    swatches.push({ hex, name: name || hex, role: role ?? (isNeutral(hex) ? "neutral" : undefined) });
    return true;
  };

  // 1. context.dev vendor colors — role by index.
  const vendor = args.vendorColors ?? [];
  vendor.forEach((c, i) => {
    if (add(c.hex, c.name ?? `brand ${i + 1}`, i === 0 ? "primary" : i === 1 ? "secondary" : i === 2 ? "accent" : undefined)) {
      sources.vendor++;
    }
  });

  // 2-4. homepage evidence: theme-color, brand CSS vars, dominant ranked.
  const ev = args.evidence;
  if (ev && !ev.fetch_error) {
    if (add(ev.meta.theme_color, "theme-color")) sources.theme_color++;
    for (const v of ev.brand_css_vars) {
      if (add(v.value, v.name.replace(/^--/, ""))) sources.css_vars++;
    }
    for (const c of ev.colors_ranked) {
      if (add(c.hex, c.via[0] ?? "dominant")) sources.ranked++;
    }
  }

  // 5. vision-on-screenshot fallback — only while still short of the gate.
  if (swatches.length < PALETTE_TARGET && args.screenshotUrl) {
    const vis = await visionColors(args.openrouterApiKey, args.screenshotUrl, args.brandName ?? "this brand");
    for (const c of vis) {
      if (add(c, "vision")) sources.vision++;
    }
  }

  return { swatches, hexes: swatches.map((s) => s.hex), sources };
}

/** Classify the unioned swatches into the legacy primary/secondary/accent/
 *  neutrals/all shape the design-tokens response exposes. Pure derivation
 *  from the unioned set — no re-fetch. */
export function classifyUnion(swatches: Swatch[]): {
  primary: string | null;
  secondary: string | null;
  accent: string | null;
  neutrals: string[];
  all: string[];
} {
  const neutrals: string[] = [];
  const chromatic: string[] = [];
  for (const s of swatches) {
    (isNeutral(s.hex) ? neutrals : chromatic).push(s.hex);
  }
  return {
    primary: chromatic[0] ?? swatches[0]?.hex ?? null,
    secondary: chromatic[1] ?? null,
    accent: chromatic[2] ?? null,
    neutrals,
    all: swatches.map((s) => s.hex),
  };
}
