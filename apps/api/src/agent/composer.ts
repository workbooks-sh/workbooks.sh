// Composer — turns a Strategy + Plan + research into the FINAL outline:
//   - what each slide/section says (its angle, what evidence anchors it)
//   - what images need to exist and what they should DO in service of the
//     argument (not just "hero image" — "hero image that makes the thesis
//     concrete: <specific scene>")
//
// This is where shallow-bullets becomes a real deck. The composer reads the
// thesis + insights + research and decides the outline AFTER thinking, not
// before.

import { chatJson, MODELS } from "../llm.js";
import type { KeyBag, Plan } from "./planner.js";
import type { Strategy } from "./strategist.js";

export interface ComposedNode {
  kind: "slide" | "section";
  /** Headline / section title — the literal text the reader sees first. */
  title: string;
  /** Tight summary of what this section/slide is arguing. Used as the writer's brief. */
  angle: string;
  /** Which insights from the strategy this node anchors on (by index). */
  insight_refs: number[];
  /** Which research verb outputs this node specifically draws on. */
  evidence_refs: string[];
  /** Optional structured-data widget the renderer knows how to lay out. */
  data_kind?: "palette" | "products" | "ads" | "competitors" | "timeline" | "stat" | "quote" | "table";
  /** Optional image binding (ref into images_pool below). */
  image_ref?: string;
}

export interface ComposedImage {
  ref: string;
  /** What this image MEANS in the workbook (its argument). */
  intent: string;
  /** Full prompt for the image-gen model. */
  prompt: string;
  aspect_ratio: string;
  use_brand_screenshot?: boolean;
}

export interface Composition {
  /** Final picked format (may override the planner's pick if strategy recommended otherwise). */
  format: "document" | "presentation";
  title: string;
  /** One-line subtitle / dek that appears under the title. */
  dek: string;
  outline: ComposedNode[];
  images: ComposedImage[];
  /** Voice constraints the writer must honor — tone, register, jargon level. */
  voice_constraints: string[];
}

const SYSTEM = `You are designing a workbook AFTER a strategist has already formed the thesis. Your job: turn the thesis + insights + research into a CONCRETE outline + image plan.

You will see:
  - The user's original request
  - The strategist's thesis + insights + narrative_arc + gaps
  - The compacted research findings

Output the outline + image briefs.

RULES:
1. Every outline node has a clear ANGLE — what is this section/slide ARGUING? "Visual identity" is a topic, not an angle; "Vercel's deliberate restraint with chromatic accent is the brand signal" is an angle.
2. Map each node to insight refs (indexes from the strategy.insights array) so the writer knows what evidence to cite.
3. Pick the narrative ORDER based on strategy.narrative_arc. Don't default to "intro → details → conclusion" — let the arc dictate.
4. Image briefs must serve the argument. "Hero image of Vercel logo" is bad; "Hero: solo small black ▲ on vast off-white field, single magenta dot in upper-right — the entire brand identity in one composition" is good.
5. Include data widgets where they LAND HARDER than prose (palette grid for visual identity, competitor matrix for positioning, ads list for voice).
6. Cap: 8 outline nodes max, 5 images max.

Format choice:
  - If strategy.format_recommendation is set, honor it.
  - Otherwise default to the format the planner picked.

Voice constraints — derive from the user request (CMO memo = direct + evidence-based; pitch deck = punchy + confident; brand book = poetic + grounded).

Reply with ONLY JSON, no markdown:
{
  "format": "document" | "presentation",
  "title": "...",
  "dek": "<= 140 chars subtitle that lands the thesis",
  "outline": [
    {
      "kind": "slide" | "section",
      "title": "...",
      "angle": "what is this arguing",
      "insight_refs": [0, 2],
      "evidence_refs": ["scrape", "competitor:hoka"],
      "data_kind": "palette" | "products" | "ads" | "competitors" | "stat" | "quote" | null,
      "image_ref": "hero" | null
    }
  ],
  "images": [
    {
      "ref": "hero",
      "intent": "what this image PROVES",
      "prompt": "detailed art-direction prompt",
      "aspect_ratio": "16:9" | "1:1" | "9:16" | "4:5",
      "use_brand_screenshot": true | false
    }
  ],
  "voice_constraints": ["3-5 short bullets describing tone + register"]
}`;

export async function composeOutline(args: {
  keys: KeyBag;
  userQuery: string;
  plan: Plan;
  strategy: Strategy;
  compactResearch: unknown;
}): Promise<{ composition: Composition; latency_ms: number; cost_usd?: number }> {
  const userPrompt = JSON.stringify({
    user_request: args.userQuery,
    planner_chose: { format: args.plan.format, title: args.plan.title },
    strategy: args.strategy,
    research_findings: args.compactResearch,
  }, null, 2);

  const { value, latency_ms, usage } = await chatJson<Composition>(args.keys, {
    model: MODELS.planner,
    messages: [
      { role: "system", content: SYSTEM },
      { role: "user", content: userPrompt },
    ],
    temperature: 0.5,
    max_tokens: 6000,
  });

  // Defensive fixups
  value.format = value.format === "document" ? "document" : (args.strategy.format_recommendation ?? args.plan.format);
  value.outline = Array.isArray(value.outline) ? value.outline.slice(0, value.format === "presentation" ? 10 : 8) : [];
  value.images = Array.isArray(value.images) ? value.images.slice(0, 5) : [];
  value.voice_constraints = Array.isArray(value.voice_constraints) ? value.voice_constraints.slice(0, 6) : [];
  value.dek = (value.dek ?? "").slice(0, 200);
  value.title = (value.title ?? args.plan.title).slice(0, 200);

  // Filter image_refs that don't exist
  const validRefs = new Set(value.images.map((i) => i.ref));
  for (const node of value.outline) {
    if (node.image_ref && !validRefs.has(node.image_ref)) delete node.image_ref;
  }

  return { composition: value, latency_ms, cost_usd: usage.cost_usd };
}
