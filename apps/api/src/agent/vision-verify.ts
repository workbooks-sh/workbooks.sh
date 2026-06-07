// Vision verifier — passes the homepage screenshot through OpenRouter to a
// vision-capable model + asks it to confirm or revise the style_signal that
// text-only Cerebras inferred from CSS evidence.
//
// We route via OpenRouter so swapping models is one constant change. Default
// is minimax/minimax-m3 (text-out, vision-input: image/video → text; 1M ctx,
// cheap). Swap MODEL below to change.
//
// Two-model design:
//   - Cerebras GLM-4.7 (text-only): style_signal from CSS evidence + meta.
//   - Vision model (here): looks at the screenshot, either CONFIRMS or REVISES
//     the style_signal, plus surfaces visual observations (composition,
//     imagery type, density) that text-only can't see.
//
// Falls back silently if OPENROUTER_API_KEY isn't set OR if the screenshot
// won't load yet (mshots returns a placeholder until WordPress caches the
// real capture — first call to a new domain).

import { imagePart } from "../llm/image-input.js";

const MODEL = "minimax/minimax-m3";
const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const REFERER = "https://brandnana.net";
const X_TITLE = "brandnana";

export interface VisionVerdict {
  /** Did vision agree with the text-derived style_signal? */
  agreed: boolean;
  /** Vision's preferred one-line style summary. Replaces text version if agreed=false. */
  style_signal_revised: string;
  /** 3-5 visual observations (mood, composition, imagery type) text can't see. */
  visual_notes: string[];
  /** Specific claims the screenshot CONTRADICTED — e.g. "no red is visible". */
  refutations: string[];
  /** Dominant colors the model actually saw in the image (sanity check vs CSS). */
  observed_colors: string[];
  /** Imagery type: "photography" | "illustration" | "flat-color" | "mixed" | "video". */
  imagery_type: string;
  /** Telemetry. */
  model: string;
  latency_ms: number;
  prompt_tokens: number;
  completion_tokens: number;
}

interface OpenRouterResponse {
  choices?: Array<{ message?: { content?: string } }>;
  usage?: { prompt_tokens?: number; completion_tokens?: number };
  model?: string;
}

/**
 * Verify the style_signal claim against the homepage screenshot. Returns null
 * if vision is not configured / unavailable.
 */
export async function verifyStyleViaVision(args: {
  openrouterApiKey: string | undefined;
  screenshotUrl: string;
  brand_name: string;
  domain: string;
  claimed_style_signal: string;
  text_evidence_summary: string;
  /** Override the default vision model — useful for evals / A/B comparison. */
  model?: string;
}): Promise<VisionVerdict | null> {
  if (!args.openrouterApiKey) return null;
  if (!args.screenshotUrl) return null;

  const t0 = Date.now();
  const model = args.model ?? MODEL;

  // Don't HEAD-check the screenshot ourselves — OpenRouter / the vision model
  // fetches it. If mshots is still rendering, the model gets a placeholder
  // and either ignores it gracefully or returns a "blank/loading" verdict.
  const prompt = `You are verifying a brand-strategist's style claim against the actual screenshot of a website.

Brand: ${args.brand_name}  (${args.domain})

Text-derived style_signal (from CSS evidence — may be wrong, you decide):
  "${args.claimed_style_signal}"

What the text model saw (no image):
  ${args.text_evidence_summary}

YOUR JOB:
1. Look at the screenshot.
2. Identify the dominant colors actually visible (top 3-5, as hex).
3. Classify the imagery type: photography | illustration | flat-color | mixed | video.
4. Decide whether the claimed style_signal accurately describes what you see.
5. If the screenshot is blank / placeholder / loading, set imagery_type to "blank" and agreed:true (no reason to override an evidence-grounded claim with nothing).
6. If you disagree, write a better one-line style_signal_revised based ONLY on visible evidence + list refutations.

Reply with ONLY this JSON, no markdown:
{
  "agreed": boolean,
  "style_signal_revised": "<= 140 chars, art-director shorthand",
  "visual_notes": ["3-5 short bullets, each <= 100 chars"],
  "refutations": ["specific claims the screenshot CONTRADICTS, empty if none"],
  "observed_colors": ["#hex", "#hex", ...],
  "imagery_type": "photography|illustration|flat-color|mixed|video|blank"
}`;

  let raw: string;
  let usage: OpenRouterResponse["usage"];
  let modelUsed: string = model;
  try {
    const r = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        authorization: `Bearer ${args.openrouterApiKey}`,
        "content-type": "application/json",
        // OpenRouter prefers these for billing/attribution + leaderboard credit.
        "http-referer": REFERER,
        "x-title": X_TITLE,
      },
      body: JSON.stringify({
        model,
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: prompt },
              await imagePart(args.screenshotUrl),
            ],
          },
        ],
        temperature: 0.2,
        max_tokens: 800,
        response_format: { type: "json_object" },
      }),
    });
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      console.warn(`[vision] OpenRouter ${r.status}: ${text.slice(0, 200)}`);
      return null;
    }
    const data = (await r.json()) as OpenRouterResponse;
    raw = data.choices?.[0]?.message?.content ?? "";
    usage = data.usage;
    modelUsed = data.model ?? model;
  } catch (e) {
    console.warn(`[vision] threw: ${(e as Error).message}`);
    return null;
  }

  let parsed: Partial<VisionVerdict>;
  try {
    // Some models wrap JSON in markdown fences despite response_format.
    const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
    parsed = JSON.parse(cleaned) as Partial<VisionVerdict>;
  } catch (e) {
    console.warn(`[vision] couldn't parse JSON: ${raw.slice(0, 200)}`);
    return null;
  }

  return {
    agreed: parsed.agreed ?? true,
    style_signal_revised: (parsed.style_signal_revised ?? args.claimed_style_signal).slice(0, 140),
    visual_notes: (parsed.visual_notes ?? []).slice(0, 5).map((s) => String(s).slice(0, 100)),
    refutations: (parsed.refutations ?? []).slice(0, 5).map((s) => String(s).slice(0, 100)),
    observed_colors: (parsed.observed_colors ?? []).slice(0, 8).map((s) => String(s)),
    imagery_type: String(parsed.imagery_type ?? "unknown").slice(0, 24),
    model: modelUsed,
    latency_ms: Date.now() - t0,
    prompt_tokens: usage?.prompt_tokens ?? 0,
    completion_tokens: usage?.completion_tokens ?? 0,
  };
}
