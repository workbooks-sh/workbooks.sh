// Strategist — the thinking step. Reads ALL the research the agent gathered
// and forms a thesis / argument / point of view BEFORE deciding what the
// workbook should look like.
//
// Without this layer the workbook is vanilla — slides filled with raw data
// in default order. With this layer, the workbook has a SPINE: a thesis
// statement, supporting insights tied to specific evidence, a narrative arc.
//
// Uses DeepSeek v4 Pro (the "thinker") because this is where reasoning
// quality matters most. ~30s per call; runs once per workbook.

import { chatJson, MODELS } from "../llm.js";
import type { KeyBag } from "./planner.js";
import type { ResearchOutcome } from "./executor.js";

export interface Insight {
  /** One-line claim the agent is willing to defend. */
  claim: string;
  /** Specific evidence references — verb names + a short pull-quote. */
  evidence: Array<{ verb: string; detail: string }>;
  /** How important is this insight to the deliverable. 1 = nice-to-have, 5 = anchor. */
  weight: number;
}

export interface Strategy {
  /** The single sentence the whole workbook is arguing for. */
  thesis: string;
  /** Why this thesis matters to the audience the user asked for. */
  stakes: string;
  /** Key insights pulled from the research, weighted. */
  insights: Insight[];
  /** Recommended narrative arc — how the workbook should unfold. */
  narrative_arc: string;
  /** Honest acknowledgement of gaps in the research the writer should NOT paper over. */
  gaps: string[];
  /** Confidence 0-1 that we have enough signal to make this argument. */
  confidence: number;
  /** Optional override: if the research warrants a different format than the
   *  planner picked (e.g. complex audit → document, brief campaign → presentation). */
  format_recommendation?: "document" | "presentation";
}

const SYSTEM = `You are a senior strategist. The agent ran research; now YOU read the findings and form a position.

Don't summarize. STRATEGIZE.

You will see:
  - The user's original request (the audience + intent)
  - The verbs the agent ran and their actual outputs (CSS evidence, brand colors, fonts, ad copy, competitor data, scraped page text)

Your job:
1. Figure out the SPINE of the workbook — one defensible thesis sentence the whole thing argues for.
2. Identify 4-7 insights that emerged FROM THE DATA (not from your priors). Each insight cites specific evidence.
3. Score each insight's weight (1-5) so the writer knows which to anchor on.
4. Note honest gaps — where the research is thin, the writer should hedge rather than invent.
5. Recommend a narrative arc — how should the workbook unfold? (chronological / dialectical / problem-solution / contrast / build-to-recommendation)
6. Recommend format ONLY if the research suggests a different fit than was originally planned.

Be specific. "Vercel's site is minimal" is bad; "Vercel's homepage uses one chromatic accent (#f05100) sparingly against a #000/#fff base — the rare use of color is the brand signal" is good.

Reply with ONLY JSON, no markdown:
{
  "thesis": "one defensible sentence",
  "stakes": "why this matters to the audience",
  "insights": [
    {"claim": "...", "evidence": [{"verb": "scrape", "detail": "..."}], "weight": 1-5}
  ],
  "narrative_arc": "describe the through-line in one sentence",
  "gaps": ["honest list of things we didn't find or couldn't verify"],
  "confidence": 0-1,
  "format_recommendation": "document" | "presentation"
}`;

export async function strategize(args: {
  keys: KeyBag;
  userQuery: string;
  research: ResearchOutcome[];
  currentFormat: "document" | "presentation";
}): Promise<{ strategy: Strategy; latency_ms: number; cost_usd?: number }> {
  // Compact the research into something the LLM can reason about — keep the
  // signal, drop the chrome. ~800 chars per verb max.
  const compactResearch = args.research
    .filter((r) => r.status === "ok")
    .map((r) => {
      const payload = compactPayload(r.step.verb, r.payload);
      return {
        verb: r.step.verb,
        args: r.step.args,
        signal: payload,
      };
    });

  const userPrompt = JSON.stringify({
    user_request: args.userQuery,
    current_format: args.currentFormat,
    research_findings: compactResearch,
  }, null, 2);

  // DeepSeek v4 Flash is fast and capable enough; Pro takes too long.
  const { value, latency_ms, usage } = await chatJson<Strategy>(args.keys, {
    model: MODELS.planner, // deepseek-v4-flash
    messages: [
      { role: "system", content: SYSTEM },
      { role: "user", content: userPrompt },
    ],
    temperature: 0.6,
    max_tokens: 4000,
  });

  // Defensive fixups
  value.insights = Array.isArray(value.insights) ? value.insights.slice(0, 8) : [];
  value.gaps = Array.isArray(value.gaps) ? value.gaps.slice(0, 6) : [];
  value.thesis = (value.thesis ?? "").trim();
  value.narrative_arc = (value.narrative_arc ?? "").trim();
  value.confidence = typeof value.confidence === "number" ? Math.max(0, Math.min(1, value.confidence)) : 0.5;

  return { strategy: value, latency_ms, cost_usd: usage.cost_usd };
}

function compactPayload(verb: string, p: unknown): unknown {
  if (!p) return null;
  const x = p as any;
  switch (verb) {
    case "scrape":
      return {
        title: x.meta?.title,
        description: x.meta?.description,
        og_title: x.meta?.og_title,
        og_description: x.meta?.og_description,
        brand_css_vars: (x.brand_css_vars ?? []).slice(0, 15).map((v: any) => ({ name: v.name, value: v.value })),
        colors_ranked: (x.colors_ranked ?? []).slice(0, 6),
        fonts: (x.fonts ?? []).slice(0, 4),
      };
    case "multipage": {
      const pages = (x.pages ?? []).slice(0, 3);
      return pages.map((p: any) => ({
        url: p.url,
        kind: p.kind,
        title: p.title,
        text_excerpt: (p.text ?? "").slice(0, 600),
      }));
    }
    case "verify_brand":
      return { confidence: x.confidence, observed_name: x.observed_name, trust: x.trust };
    case "logo":
      return x.result ? { url: x.result.url, source: x.result.source, content_type: x.result.content_type } : { failed: true };
    case "screenshot":
      return { url: x.url };
    case "competitor":
      return {
        observed_name: x.verify?.observed_name,
        title: x.evidence?.meta?.title,
        colors: (x.evidence?.colors_ranked ?? []).slice(0, 4),
        fonts: (x.evidence?.fonts ?? []).slice(0, 2).map((f: any) => f.family),
        logo: x.logo?.result?.url,
      };
    default:
      return JSON.stringify(p).slice(0, 500);
  }
}
