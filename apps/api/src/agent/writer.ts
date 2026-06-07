// Writer — one LLM call per section/slide. Writes the actual content with
// depth, citing specific findings from research + insights from strategy.
//
// Parallelized: 6-section deck = 6 simultaneous LLM calls; total wall-clock
// ~5-8s. Each call is small + focused — the writer sees ONLY the angle,
// relevant insights, and the evidence those insights cite.
//
// Why per-section instead of one giant write: focus. A single call writing
// 6 sections has to juggle 6 arguments, runs over token budget, and tends to
// lose voice between sections. One call per section keeps each tight + lets
// us retry just the weakest section without redoing everything.

import { chatJson, MODELS } from "../llm.js";
import type { KeyBag } from "./planner.js";
import type { Strategy, Insight } from "./strategist.js";
import type { ComposedNode, Composition } from "./composer.js";

export interface WrittenSection {
  /** The node's title — copied through unchanged so the renderer can theme it. */
  title: string;
  /** The kind from the composer. */
  kind: "slide" | "section";
  /** The actual prose body. 2-4 short paragraphs for presentation, 4-8 for document. */
  body: string;
  /** Optional pull-quote / stat the writer wants to feature alongside the body. */
  highlight?: { kind: "quote" | "stat"; payload: { value?: string; label?: string; quote?: string; attribution?: string } };
  /** Image ref binding (passed through from composition). */
  image_ref?: string;
  /** Structured data widget the writer wants — they may suggest one even if composer didn't. */
  data_kind?: ComposedNode["data_kind"];
  /** Telemetry. */
  meta: { tokens: number; latency_ms: number };
}

const SYSTEM_DOC = `You are writing one SECTION of a long-form document. You have a thesis, an angle for this section, the insights that anchor it, and the relevant research excerpts.

Write 3-6 short paragraphs of body prose. Standards:
  - Reference SPECIFIC findings (e.g. "Vercel's --color-primary CSS variable is set to #f05100, used only on CTAs"), not generic claims.
  - Make every paragraph earn its place. No filler. No throat-clearing intros.
  - Honor the voice constraints.
  - Inline markdown allowed: **bold**, *italic*, \`code\`, [text](url). No headers.
  - Do NOT repeat the section title in the body.
  - If the writer wants to feature a stat or quote alongside the body, return it as highlight.

Reply with ONLY JSON, no markdown:
{
  "body": "the prose, 3-6 paragraphs, separated by blank lines",
  "highlight": {"kind": "stat", "payload": {"value": "#f05100", "label": "Vercel's single chromatic accent"}}
}`;

const SYSTEM_SLIDE = `You are writing one SLIDE of a presentation. You have a thesis, an angle for this slide, the insights it anchors, and the research excerpts.

Write 1-3 short paragraphs of body text — TIGHT. Slides aren't documents.

Standards:
  - Lead with the most arresting line — what the audience should remember from this slide.
  - Reference SPECIFIC findings, not generic claims.
  - Match the voice constraints. Punchy if pitch deck; restrained if brand book.
  - If the slide will have a structured data widget (palette/products/ads/etc) or an image, the body should COMPLEMENT it, not duplicate it.
  - Inline markdown allowed: **bold**, *italic*. No headers, no lists in slides.
  - Do NOT repeat the slide title.
  - Optional highlight: a single big stat or pull-quote that lands harder than the body.

Reply with ONLY JSON, no markdown:
{
  "body": "1-3 short paragraphs",
  "highlight": {"kind": "quote", "payload": {"quote": "...", "attribution": "..."}}
}`;

interface WriteSectionArgs {
  keys: KeyBag;
  userQuery: string;
  format: "document" | "presentation";
  node: ComposedNode;
  strategy: Strategy;
  voiceConstraints: string[];
  /** Compacted research findings (same shape passed to strategist). */
  compactResearch: unknown;
}

async function writeOne(args: WriteSectionArgs): Promise<WrittenSection> {
  const t0 = Date.now();
  const system = args.format === "document" ? SYSTEM_DOC : SYSTEM_SLIDE;

  // Pull just the insights this node references — saves tokens + focuses the writer.
  const relevantInsights: Insight[] = (args.node.insight_refs ?? [])
    .map((i) => args.strategy.insights[i])
    .filter((x): x is Insight => !!x);

  const userPrompt = JSON.stringify({
    section_title: args.node.title,
    section_angle: args.node.angle,
    user_request: args.userQuery,
    workbook_thesis: args.strategy.thesis,
    narrative_arc: args.strategy.narrative_arc,
    relevant_insights: relevantInsights,
    voice_constraints: args.voiceConstraints,
    research_findings: args.compactResearch,
  }, null, 2);

  try {
    const { value, usage } = await chatJson<{ body?: string; highlight?: any }>(args.keys, {
      model: MODELS.planner,
      messages: [
        { role: "system", content: system },
        { role: "user", content: userPrompt },
      ],
      temperature: 0.7,
      max_tokens: args.format === "document" ? 3000 : 1500,
    });
    return {
      title: args.node.title,
      kind: args.node.kind,
      body: (value.body ?? "").trim() || "(writer returned empty)",
      highlight: value.highlight && typeof value.highlight === "object" ? value.highlight : undefined,
      image_ref: args.node.image_ref,
      data_kind: args.node.data_kind,
      meta: { tokens: usage.completion_tokens, latency_ms: Date.now() - t0 },
    };
  } catch (e) {
    return {
      title: args.node.title,
      kind: args.node.kind,
      body: `(writer error: ${(e as Error).message})`,
      image_ref: args.node.image_ref,
      data_kind: args.node.data_kind,
      meta: { tokens: 0, latency_ms: Date.now() - t0 },
    };
  }
}

/** Write every section/slide in the composition in parallel. */
export async function writeAllSections(args: {
  keys: KeyBag;
  userQuery: string;
  composition: Composition;
  strategy: Strategy;
  compactResearch: unknown;
}): Promise<WrittenSection[]> {
  return Promise.all(
    args.composition.outline.map((node) =>
      writeOne({
        keys: args.keys,
        userQuery: args.userQuery,
        format: args.composition.format,
        node,
        strategy: args.strategy,
        voiceConstraints: args.composition.voice_constraints,
        compactResearch: args.compactResearch,
      }),
    ),
  );
}
